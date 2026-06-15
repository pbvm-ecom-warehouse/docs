# Spec: Kế hoạch 4 tuần hiện thực hóa app WMS

> Trạng thái: ✅ Đã chốt thiết kế (brainstorm 2026-06-15) — đầu vào cho `writing-plans`.
> Topic: sprint plan + issue backlog cho việc code app WMS từ bộ docs đã có.

## 1. Bối cảnh & mục tiêu

Bộ tài liệu phân tích nghiệp vụ đã gần hoàn chỉnh (7 module thiết kế xong + DB guide). Bước tiếp theo là **hiện thực hóa code** trong **4 tuần**, đồng thời viết nốt 2 module docs còn thiếu (Notification, Report).

**Định nghĩa "done" cuối tuần 4:** app **WMS nội bộ chạy vững** — toàn bộ luồng kho end-to-end:

```
PO → GRN (nhập) → Put-away (+ gợi ý vị trí) → Xuất kho → Kiểm kê → Chuyển kho → In ly
```

**Ngoài phạm vi (YAGNI 4 tuần):** Ecommerce/catalog, giỏ hàng, checkout/thanh toán, shipping API hãng. Chỉ **chừa interface event** `stock.changed` để sau nối Ecom.

## 2. Ràng buộc & bất biến (phải giữ khi code)

- **Stack:** NestJS monorepo — `apps/wms` + `libs/{auth,database,shared-types,common}`; MongoDB logical DB `wms_db`; BullMQ + Redis cho event. Bám [overview/nestjs-monorepo.md](../../overview/nestjs-monorepo.md).
- **Tồn 2 lớp:** `StockBalance.onHand` (lớp tổng) = Σ `InventoryStock.quantity` mọi shelf; `available = onHand − reserved − expired`. Mọi biến động cập nhật **cả 2 lớp trong 1 transaction**.
- **`StockMovement`** = sổ cái append-only đối soát mọi biến động tồn.
- **Barcode** ở mọi bước chạm hàng vật lý (GRN, put-away, pick, kiểm kê, chuyển kho).
- **Auth tách theo app:** WMS dùng collection `users` + `RolesGuard`; 1 user nhiều role (`User.roles[]`).
- **Định danh chuẩn** (collection/enum/event) khớp [data-ownership.md](../../overview/data-ownership.md) và [system-context.md](../../overview/system-context.md).

## 3. Đội & cadence

- **Đội:** 2-3 dev, code từ đầu (scaffold mới).
- **Cadence:** 4 sprint × 1 tuần. Mỗi sprint chừa 1 "track docs" nhỏ chạy song song để hoàn thiện Notification + Report mà không chặn track code.

## 4. Cấu trúc folder issues

```
planning/
  README.md                        ← tổng quan 4 sprint, legend nhãn, cách map sang GitHub
  sprint-1-foundation.md           ← mục tiêu sprint + checklist issue (link tới issues/)
  sprint-2-inbound.md
  sprint-3-outbound-internal.md
  sprint-4-hardening-reports.md
  issues/
    S1-01-scaffold-monorepo.md     ← 1 file = 1 issue
    S1-02-...
  scripts/
    create-issues.sh               ← gh issue create đọc từng file (chạy sau khi cài gh)
```

**Mỗi file issue** chứa: tiêu đề, nhãn, sprint, ước lượng, `depends-on`, mô tả, **acceptance criteria**, link docs nguồn.

**Nhãn issue:**
- `type:` — `infra` | `feat` | `docs` | `test`
- `module:` — `warehouse` | `auth` | `supplier` | `report` | `notification`
- `sprint:N` (1–4)
- `size:` — `S` (≤0.5d) | `M` (~1-2d) | `L` (~3d+)
- `depends-on:` — mã issue tiền đề

## 5. Bốn sprint

### Sprint 1 — Nền móng & Auth (Week 1)
- **S1-01** Scaffold monorepo (`apps/wms`, `libs/*`), cấu hình env, kết nối `wms_db`, Swagger. `infra/L`
- **S1-02** Auth-WMS: `User` schema, login, JWT access + refresh (thu hồi DB), `RolesGuard`, seed ADMIN. `feat/L` (dep S1-01)
- **S1-03** Schema cấu trúc kho: Warehouse/Zone/Rack/Shelf (+ kích thước) + CRUD. `feat/M` (dep S1-01)
- **S1-04** Schema tồn 2 lớp: `WarehouseItem`, `StockBalance`, `InventoryStock`, `StockMovement` + helper transaction cập nhật cả 2 lớp. `feat/L` (dep S1-01)
- **S1-05** *(docs)* Viết module `notification/` (consumer `stock.low`, `stock.near_expiry`; template; idempotent). `docs/M`

### Sprint 2 — Nhập kho (Week 2)
- **S2-01** Supplier + `SupplierItem` (bảng giá 1 NCC/SKU, blacklist, guard giá khi tạo PO). `feat/M`
- **S2-02** UC-01 Purchase Order: tạo PO, trạng thái, gợi ý giá. `feat/M` (dep S2-01)
- **S2-03** UC-02 GRN: nhận hàng, lot/expiry hàng `isPerishable`, `onHand +=` trong transaction, barcode, sinh `StockMovement`. `feat/L` (dep S1-04, S2-02)
- **S2-04** UC-03 Put-away: chuyển staging→shelf thật, quét SKU+shelf, khớp dòng GRN. `feat/L` (dep S2-03)
- **S2-05** Thuật toán gợi ý vị trí put-away (best-fit theo thể tích, ràng buộc lọt 3 chiều, gom cùng SKU — theo [warehouse/workflow.md WF-01](../../warehouse/workflow.md)). `feat/M` (dep S2-04)
- **S2-06** Hạ tầng event: BullMQ/Redis, publisher, phát `stock.changed` sau biến động tồn. `infra/M` (dep S1-04)

### Sprint 3 — Xuất kho & nội bộ (Week 3)
- **S3-01** UC-05 Soạn & xuất hàng: pick list, quét SKU+shelf, reserve→trừ tồn (2 lớp/transaction), phát `goods.issued`. `feat/L` (dep S1-04, S2-06)
- **S3-02** UC-04 In ly (make-to-order): `PrintJob`, hold `CUP_BLANK` → chuyển `CUP_PRINTED` cho đúng đơn. `feat/L` (dep S1-04)
- **S3-03** UC-06 Kiểm kê & điều chỉnh tồn: phiên đếm, chênh lệch → adjustment + `StockMovement`. `feat/M` (dep S1-04)
- **S3-04** UC-07 Chuyển kho: xuất kho nguồn → nhận kho đích, giữ nhất quán 2 lớp. `feat/L` (dep S3-01)

### Sprint 4 — Hoàn thiện & Báo cáo (Week 4)
- **S4-01** UC-08 Scrap (hủy hết hạn/hỏng) — đề xuất + duyệt. `feat/M`
- **S4-02** UC-09 Return/RMA — nhận hoàn về kho. `feat/M`
- **S4-03** Module Report: tồn theo SKU/kho/lô, hiệu suất nhập/xuất/kiểm (read-only). `feat/L`
- **S4-04** Notification consumer thật: `stock.low`, `stock.near_expiry`. `feat/M` (dep S1-05)
- **S4-05** Seed data + E2E happy-path WMS + bug bash + chuẩn bị demo. `test/L`
- **S4-06** *(docs)* Viết nốt module `report/`. `docs/M`

## 6. Đẩy lên GitHub

1. Sinh toàn bộ markdown trong `planning/`; commit + push qua SSH về repo docs (`git@github.com:pbvm-ecom-warehouse/docs.git`).
2. Tạo GitHub Issues: `gh` **chưa cài** trong môi trường. Chuẩn bị `planning/scripts/create-issues.sh` (vòng lặp `gh issue create --title ... --body-file ... --label ...`). Sau khi user cài `gh` + `gh auth login`, **hỏi user trước** rồi chạy script.

## 7. Ngoài phạm vi (ghi nhận)

- Ecommerce/catalog, giỏ hàng, checkout, thanh toán, shipping API hãng — sprint sau.
- Consumer `stock.changed` phía Ecom (chỉ phát event, chưa có consumer).
- Báo cáo doanh thu/đơn hàng (cần dữ liệu Order) — ngoài WMS.
