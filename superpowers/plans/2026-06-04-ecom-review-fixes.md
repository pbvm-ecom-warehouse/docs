# Ecom Review Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sửa docs ecom theo [spec 2026-06-04-ecom-review-design](../specs/2026-06-04-ecom-review-design.md): vá mâu thuẫn reserve, thêm mạch event fulfillment 2 chiều, ghi nhận YAGNI — giữ nhất quán chéo file.

**Architecture:** Repo tài liệu (markdown tiếng Việt), **không có build/test**. "Verify" = (a) anchor/link phân giải đúng, (b) tên event/enum nhất quán giữa các file, (c) không còn mô tả cũ (`order.placed` reserve, `stock.changed` cho reserve/cancel). Nguồn chuẩn định danh = [data-ownership.md](../../overview/data-ownership.md) → sửa file này **trước**, rồi lan ra các file tham chiếu.

**Tech Stack:** Markdown, `grep` để verify.

**Thứ tự thực hiện (theo phụ thuộc):** data-ownership → main-flow → order/* → catalog/* → gap-analysis. Mỗi Task = 1 file, commit riêng.

**Quy ước commit:** prefix `docs(ecom): ...`, kết thúc bằng:
```
Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
```

**Tên định danh chuẩn (dùng y hệt mọi nơi):**
- Event mới: `print.completed` (WMS→Ecom), `order.ready_to_fulfill` (Ecom→WMS).
- `order.placed` = **thông báo thuần**, KHÔNG reserve. `order.cancelled` = thông báo thuần, release đã làm in-transaction.
- Reserve/release = **transaction atomic xuyên 2 DB**: `reserved ±= qty` (`wms_db.stock_balances`) + `availableQty ∓= qty` (`ecom_db.product_variants`), không qua event.

---

### Task 1: data-ownership.md (nguồn chuẩn event)

**Files:**
- Modify: `overview/data-ownership.md`

- [ ] **Step 1: Sửa hàng `stock.changed` trong bảng event** (mục "Các event đồng bộ…")

Thay mô tả hàng `stock.changed` — bỏ "giữ hàng khi chốt đơn, hủy đơn", thêm ghi chú self-update:

```
| `stock.changed` | WMS | Ecommerce | **Khi `available` (tổng gộp mọi kho) đổi do biến động phía WMS**: nhập kho (GRN), kiểm kho điều chỉnh, chuyển kho (reserve nguồn lúc `CONFIRMED` −/nhận đích +), in ly (blank↓ khi tạo lệnh; printed↑ **chỉ khi in vào kho, không gắn đơn**), hoàn hàng. *(KHÔNG bắn khi: put-away, pick-xuất, **scrap**; **cũng KHÔNG bắn cho reserve/release lúc checkout/hủy đơn** — Ecom tự trừ/cộng `availableQty` ngay trong transaction, xem [Chống oversell](#chống-oversell-khi-xác-nhận-đơn))* |
```

- [ ] **Step 2: Sửa hàng `order.placed`**

```
| `order.placed` | Ecommerce | WMS | **Khách chốt đơn (cả COD/online)** → **thông báo thuần** để WMS ghi nhận đơn. **KHÔNG reserve ở đây** — tồn đã giữ atomic ngay trong transaction checkout (Ecom ghi thẳng `wms_db.stock_balances`, xem [Chống oversell](#chống-oversell-khi-xác-nhận-đơn)). Trigger xuất kho là `order.ready_to_fulfill` |
```

- [ ] **Step 3: Sửa hàng `order.cancelled`**

```
| `order.cancelled` | Ecommerce | WMS | Hủy đơn trước khi xuất → **thông báo thuần**; release reserve (`reserved −= qty`) + `availableQty += qty` đã do Ecom làm atomic trong transaction hủy. WMS ghi nhận để dừng downstream |
```

- [ ] **Step 4: Thêm 2 hàng event mới** (chèn ngay sau hàng `order.returned`)

```
| `print.completed` | WMS | Ecommerce | PrintJob của đơn in xong → Ecom set `OrderItem.printJobId`; đã in xong **mọi** ly-in của đơn → lật `fulfillmentStatus: AWAITING_PRINT → READY_TO_PICK` |
| `order.ready_to_fulfill` | Ecommerce | WMS | Đơn vào `READY_TO_PICK` (COD ngay sau checkout / online-không-in khi `payment.success` / đơn ly-in sau khi in xong) → WMS sinh `GoodsIssue` (UC-05) xuất từ `fulfillWarehouseId` |
```

- [ ] **Step 5: Thay khối "Luồng sync"** (mục "Sync tồn kho qua Event")

Thay toàn bộ tiểu mục `### Luồng sync` (cả ví dụ code-block và 2 ghi chú quanh nó) bằng:

````
### Luồng sync

`availableQty` (bản copy bên Ecom) có **2 đường cập nhật**, không trùng đếm:

**Đường 1 — biến động phía WMS** (GRN, kiểm kho, chuyển kho, in-vào-kho, hết hạn): WMS phát `stock.changed`/`stock.expired`, Ecom worker cộng dồn.

```
WMS nhập kho 200 ly (onHand += 200 → available += 200)
  → push event: { sku: "LY-500ML", delta: +200 }
        ↓
Ecommerce worker nhận event
  → product_variants.availableQty += 200
```

**Đường 2 — reserve/release lúc checkout/hủy** (do Ecom khởi xướng): Ecom tự trừ/cộng `availableQty` **ngay trong transaction** checkout/hủy, **không** qua event (xem [Chống oversell](#chống-oversell-khi-xác-nhận-đơn)).

> Lúc PICKER xuất kho thật, `onHand -= 50` và `reserved -= 50` → `available` **không đổi** → không bắn event (đã trừ từ lúc chốt đơn, tránh trừ 2 lần).
````

- [ ] **Step 6: Thêm bước `availableQty` vào khối transaction "Chống oversell"**

Thay khối code "Đặt hàng → … → commit" bằng:

```
Đặt hàng → chọn kho có available ≥ qty (ưu tiên CENTRAL) → mở transaction (xuyên 2 logical DB cùng cluster):
  1. wms_db.stock_balances: kiểm `onHand − reserved ≥ qty` rồi `reserved += qty` (atomic, khóa document)
  2. ecom_db.product_variants: `availableQty −= qty` (Ecom tự trừ bản copy của mình — không qua event)
  3. ecom_db.orders: tạo Order + OrderItem (snapshot)
  → commit cùng lúc; nếu không đủ → rollback + báo hết hàng
```

- [ ] **Step 7: Verify**

Run:
```bash
cd /home/hoaiphuong/code/wms-ecom/docs
grep -n "order.placed" overview/data-ownership.md      # mô tả phải là "thông báo thuần", không còn "WMS giữ tồn"
grep -n "print.completed\|order.ready_to_fulfill" overview/data-ownership.md   # phải xuất hiện
grep -n "giữ hàng khi chốt đơn" overview/data-ownership.md   # KHÔNG còn trong trigger stock.changed
```
Expected: `order.placed` mô tả mới; 2 event mới xuất hiện; không còn "giữ hàng khi chốt đơn" ở hàng `stock.changed`.

- [ ] **Step 8: Commit**

```bash
git add overview/data-ownership.md
git commit -m "$(printf 'docs(ecom): data-ownership — reserve in-transaction, thêm print.completed & order.ready_to_fulfill\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 2: main-flow.md (happy-path end-to-end)

**Files:**
- Modify: `overview/main-flow.md`

- [ ] **Step 1: Sửa bản đồ tổng quan (mục 1)** — khối P3 trong sơ đồ ascii

Thay 3 dòng (`◀── order.placed … reserve ATOMIC`, `reserved += qty`, `stock.changed(−) … availableQty −= qty`) bằng:

```
            │                              KHÁCH → [P1 Duyệt/Tìm]
            │                                       → [P2 Chi tiết + variant (+design)]
            │                                       → [P3 Checkout: reserve ATOMIC in-transaction]
            │ ◀── order.placed ───────────────────── │  (thông báo thuần — reserved += qty &
            │                                         │   availableQty −= qty đã làm trong transaction)
```

- [ ] **Step 2: Sửa ghi chú dưới bản đồ** (dòng bắt đầu "Mũi tên `◀──`…")

Thay câu cuối ghi chú bằng:

```
**Reserve là thao tác atomic checkout làm trong 1 transaction xuyên 2 DB** (reserve `wms_db.stock_balances` + trừ `availableQty` `ecom_db.product_variants`) — `order.placed` là **thông báo thuần**, KHÔNG reserve lại; không bắn `stock.changed` cho reserve.
```

- [ ] **Step 3: Sửa khối swimlane "P3 — Checkout"**

Thay 4 dòng cuối khối (`Tạo Order{…}`, `order.placed …`, `stock.changed{sku,−} …`, `Đơn đã tạo`) bằng:

```
 |                    Transaction atomic (xuyên 2 DB):
 |                      reserved += qty (wms_db) · availableQty −= qty (ecom_db) · tạo Order{PLACED,UNPAID,NONE}
 |                    fulfillWarehouseId; order.placed ──────>| (thông báo thuần, KHÔNG reserve lại)
 |<-- Đơn đã tạo -----------|
```

Và thay ghi chú dưới P3 (dòng "Checkout **tự** reserve atomic…") bằng:

```
> Checkout **tự** reserve atomic xuyên 2 DB (reserve `wms_db` + trừ `availableQty` `ecom_db`) trong 1 transaction — `order.placed` là **thông báo thuần**, KHÔNG reserve lại. Reserve **tách khỏi thanh toán**, giữ tồn ngay khi đặt. Fail → rollback, không tạo đơn. [WF-E01](../order/workflow.md#wf-e01-checkout--giữ-tồn).
```

- [ ] **Step 4: Sửa khối swimlane "P5 — In ly"** — dòng `Job=COMPLETED → fulfillment=READY_TO_PICK`

Thay bằng:

```
 |                    Job=COMPLETED ── print.completed ──> Ecom: đủ mọi ly-in? → fulfillment=READY_TO_PICK
```

- [ ] **Step 5: Sửa khối swimlane "P6 — Xuất kho"**

Thay toàn khối (header + 4 dòng) bằng:

```
ORDER                   WMS / PICKER             stock_balances
 | READY_TO_PICK           |                       |
 |-- order.ready_to_fulfill ->| WMS sinh GoodsIssue (UC-05)
 |                         |-- Quét + Xác nhận xuất ->| onHand−, reserved− → GoodsIssue=CONFIRMED
 |<-- goods.issued --------| fulfillment=ISSUED
```

- [ ] **Step 6: Sửa nhánh phụ "[Hủy đơn]" (mục 3)**

Thay khối `[Hủy đơn]` bằng:

```
[Hủy đơn] (trước ISSUED; ly-in trước AWAITING_PRINT)
  KHÁCH → ORDER: transaction hủy atomic (reserved −= qty `wms_db` + availableQty += qty `ecom_db`)
                 → order.cancelled (thông báo thuần) → orderStatus=CANCELLED
                 ONLINE đã PAID → REFUND_PENDING → REFUNDED.  [WF-E04]
```

- [ ] **Step 7: Sửa bảng "event timeline" (mục 4)**

Thay 5 hàng (`order.placed`, `stock.changed (−)`, `payment.success`, `print.requested`, `goods.issued`) bằng 6 hàng:

```
| P3 | `order.placed` | Ecom → WMS | Chốt đơn → **thông báo thuần** (reserve & trừ `availableQty` đã làm atomic in-transaction) |
| P4 | `payment.success` | Ecom → Notification | Trả tiền OK → email xác nhận |
| P4 | `print.requested` | Ecom → WMS | Đơn ly-in đã PAID → mở PrintJob |
| P5 | `print.completed` | WMS → Ecom | In xong → set `printJobId`; đủ mọi ly-in → `READY_TO_PICK` |
| P6 | `order.ready_to_fulfill` | Ecom → WMS | Đơn `READY_TO_PICK` → WMS sinh GoodsIssue |
| P6 | `goods.issued` | WMS → Ecom | Xuất kho xong → `fulfillment=ISSUED` (không trừ available lần nữa) |
```

- [ ] **Step 8: Sửa khối "Vòng đồng bộ tồn" (mục 5)** — dòng "WMS mọi biến động available (…)"

Thay dòng đầu khối ascii bằng:

```
WMS biến động available phía kho (GRN, kiểm kho, chuyển kho, in ly, hết hạn)
        │  stock.changed{sku, delta} / stock.expired
        │  (reserve/hủy lúc checkout do Ecom tự cập nhật in-transaction — không qua đây)
```

- [ ] **Step 9: Verify**

Run:
```bash
cd /home/hoaiphuong/code/wms-ecom/docs
grep -n "stock.changed{sku,−}\|reserve atomic (trực tiếp wms_db)" overview/main-flow.md   # KHÔNG còn
grep -n "print.completed\|order.ready_to_fulfill" overview/main-flow.md                    # phải có
grep -ohE '\]\(\.\.?/[^)#]+\.md' overview/main-flow.md | sort -u                           # link .md hợp lệ
```
Expected: mô tả cũ biến mất; 2 event mới xuất hiện; link `.md` trỏ file tồn tại.

- [ ] **Step 10: Commit**

```bash
git add overview/main-flow.md
git commit -m "$(printf 'docs(ecom): main-flow — khớp reserve in-transaction & mạch event print/ready-to-fulfill\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 3: order/use-cases.md

**Files:**
- Modify: `order/use-cases.md`

- [ ] **Step 1: UC-E02 — sửa bước 4 và 5**

Bước 4, thay bằng:

```
4. Hệ chọn kho có `available ≥ qty` (ưu tiên `CENTRAL`) → **transaction atomic xuyên 2 DB**: `reserved += qty` trên `wms_db.stock_balances` + `availableQty −= qty` trên `ecom_db.product_variants` (Ecom tự trừ bản copy, không qua event); lưu `fulfillWarehouseId`
```

Bước 5, thay cụm "(WMS đã giữ tồn trong transaction)" bằng "(**thông báo thuần** — tồn đã giữ trong transaction, WMS không reserve lại)".

- [ ] **Step 2: UC-E03 ONLINE — sửa bước 4**

Thay bằng:

```
4. Nếu `hasPrintItems` → phát `print.requested` (WMS mở PrintJob/UC-04) → `fulfillmentStatus = AWAITING_PRINT`; ngược lại → `READY_TO_PICK` → phát `order.ready_to_fulfill` (WMS sinh GoodsIssue)
```

- [ ] **Step 3: UC-E03 COD — sửa bước 2**

Thay bằng:

```
2. `orderStatus → CONFIRMED` ngay sau đặt; `fulfillmentStatus = READY_TO_PICK` → phát `order.ready_to_fulfill` (WMS sinh GoodsIssue)
```

- [ ] **Step 4: UC-E04 — chèn bước xử lý `print.completed` thành bước 1 mới, dồn các bước sau xuống**

Khối "### Luồng chính" của UC-E04 đổi thành:

```
### Luồng chính
1. **Đơn ly-in:** WMS in xong → phát `print.completed` (mang `printJobId`) → Ecom set `OrderItem.printJobId`; khi **mọi** ly-in của đơn đã in xong → `fulfillmentStatus: AWAITING_PRINT → READY_TO_PICK`
2. `READY_TO_PICK` → phát `order.ready_to_fulfill` → WMS sinh GoodsIssue (UC-05), xuất kho từ `fulfillWarehouseId`
3. `goods.issued` (WMS→Ecom) → `fulfillmentStatus = ISSUED`
4. Shipping (module sau) → `SHIPPED` → `DELIVERED`
5. `DELIVERED`: nếu COD → `paymentStatus = PAID`; `orderStatus = CLOSED`
6. Khách tra cứu trạng thái đơn theo 3 trục
```

- [ ] **Step 5: Verify**

Run:
```bash
cd /home/hoaiphuong/code/wms-ecom/docs
grep -n "order.ready_to_fulfill\|print.completed" order/use-cases.md   # phải có ở UC-E03/E04
grep -n "WMS đã giữ tồn trong transaction" order/use-cases.md          # KHÔNG còn (đã đổi thành "thông báo thuần")
```
Expected: event mới xuất hiện; cụm cũ biến mất.

- [ ] **Step 6: Commit**

```bash
git add order/use-cases.md
git commit -m "$(printf 'docs(ecom): order use-cases — order.ready_to_fulfill, xử lý print.completed, availableQty in-txn\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 4: order/workflow.md

**Files:**
- Modify: `order/workflow.md`

- [ ] **Step 1: WF-E01 — sửa khối reserve**

Thay 5 dòng (`reserve ATOMIC …` đến `fulfillWarehouseId, order.placed`) bằng:

```
  |                          |-- reserve ATOMIC (txn) -->| reserved += qty (wms_db)
  |                          |   availableQty −= qty (ecom_db, cùng txn)  (khóa document)
  |                          |<-- OK / hết hàng ---------|
  |                    Tạo Order{PLACED, UNPAID, NONE}    |
  |                    fulfillWarehouseId; order.placed (thông báo thuần)
```

- [ ] **Step 2: WF-E02 — sửa nhánh ONLINE (khối print)**

Thay 3 dòng (`Có ly-in? --yes--> …`, `fulfillment → AWAITING_PRINT … READY_TO_PICK`, `Có ly-in? --no--> READY_TO_PICK`) bằng:

```
  |                    Có ly-in? --yes--> print.requested -->| mở PrintJob (UC-04)
  |                    fulfillment → AWAITING_PRINT   |
  |                    <-- print.completed (đủ mọi ly-in) ---| in xong
  |                    fulfillment → READY_TO_PICK    |
  |                    Có ly-in? --no--> READY_TO_PICK|
  |                    READY_TO_PICK → order.ready_to_fulfill -->| (WMS sinh GoodsIssue)
```

- [ ] **Step 3: WF-E02 — sửa nhánh COD**

Thay 2 dòng (`orderStatus → CONFIRMED`, `fulfillment → READY_TO_PICK`) bằng:

```
  |                    orderStatus → CONFIRMED        |
  |                    fulfillment → READY_TO_PICK → order.ready_to_fulfill -->| (WMS sinh GoodsIssue)
```

- [ ] **Step 4: WF-E03 — sửa trigger GoodsIssue**

Thay khối (header + 5 dòng đầu, từ `WMS … SHIPPING (sau)` đến `goods.issued ──> fulfillment → ISSUED`) bằng:

```
WMS                      ORDER                     SHIPPING (sau)
  |                        |                           |
  |<-- order.ready_to_fulfill (READY_TO_PICK) --|      |
  | GoodsIssue (UC-05)     |                           |
  |-- goods.issued ------->| fulfillment → ISSUED      |
```

- [ ] **Step 5: Verify**

Run:
```bash
cd /home/hoaiphuong/code/wms-ecom/docs
grep -n "order.ready_to_fulfill\|print.completed" order/workflow.md   # phải có ở WF-E02/E03
grep -n "GoodsIssue (UC-05) ->" order/workflow.md                     # khối cũ "Sinh phiếu xuất" đã thay
```
Expected: event mới xuất hiện trong WF-E02/E03.

- [ ] **Step 6: Commit**

```bash
git add order/workflow.md
git commit -m "$(printf 'docs(ecom): order workflow — mạch print.completed & order.ready_to_fulfill\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 5: order/data-model.md

**Files:**
- Modify: `order/data-model.md`

- [ ] **Step 1: OrderItem — sửa mô tả `printJobId`**

Thay hàng `printJobId` bằng:

```
| printJobId | ObjectId | Tham chiếu PrintJob bên WMS — Ecom set khi nhận `print.completed` (WMS→Ecom) |
```

- [ ] **Step 2: Nhóm 4 — thêm ghi chú RMA không mở lại đơn**

Chèn ghi chú mới ngay sau ghi chú "**Đơn xuất nguyên kiện (không tách)**" (cuối file):

```
> **RMA không mở lại đơn:** hoàn hàng (UC-E06) xảy ra sau `DELIVERED` khi `orderStatus = CLOSED`. RMA **không** đưa `orderStatus` về trạng thái khác — chỉ chuyển `fulfillmentStatus → RETURNED` và đẩy `paymentStatus` theo luồng refund (`REFUND_PENDING → REFUNDED`) nếu hợp lệ. Đơn vẫn `CLOSED`.
```

- [ ] **Step 3: Verify**

Run:
```bash
cd /home/hoaiphuong/code/wms-ecom/docs
grep -n "print.completed\|RMA không mở lại" order/data-model.md   # cả 2 phải có
```
Expected: cả 2 cụm xuất hiện.

- [ ] **Step 4: Commit**

```bash
git add order/data-model.md
git commit -m "$(printf 'docs(ecom): order data-model — nguồn printJobId & RMA giữ orderStatus CLOSED\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 6: catalog/data-model.md & catalog/use-cases.md

**Files:**
- Modify: `catalog/data-model.md`
- Modify: `catalog/use-cases.md`

- [ ] **Step 1: catalog/data-model.md — thêm ghi chú 2 đường cập nhật**

Chèn ngay sau ghi chú cuối Nhóm 4 (dòng bắt đầu "> Variant không có `sku` khớp…"):

```
> **Hai đường cập nhật `availableQty`:** (1) biến động phía WMS → `stock.changed`/`stock.expired` (consumer ở module này); (2) reserve/release lúc checkout/hủy → module **Order** tự trừ/cộng `availableQty` **ngay trong transaction**, không qua event (xem [Order data-model](../order/data-model.md) & [data-ownership](../overview/data-ownership.md#chống-oversell-khi-xác-nhận-đơn)). Hai đường không trùng đếm.
```

- [ ] **Step 2: catalog/use-cases.md — thêm lưu ý vào UC-C06**

Chèn ngay sau ghi chú cuối UC-C06 (dòng "> Chi tiết cơ chế sync: [data-ownership]…"):

```
> **Lưu ý:** consumer này chỉ xử lý **đường WMS-event**. Reserve/release lúc checkout/hủy do module Order tự cập nhật `availableQty` trong transaction, không đi qua worker này.
```

- [ ] **Step 3: Verify**

Run:
```bash
cd /home/hoaiphuong/code/wms-ecom/docs
grep -n "Hai đường cập nhật" catalog/data-model.md
grep -n "chỉ xử lý" catalog/use-cases.md
grep -ohE '\]\(\.\.?/[^)#]+\.md' catalog/data-model.md | sort -u   # link .md hợp lệ
```
Expected: ghi chú xuất hiện ở cả 2 file; link `.md` trỏ file tồn tại.

- [ ] **Step 4: Commit**

```bash
git add catalog/data-model.md catalog/use-cases.md
git commit -m "$(printf 'docs(ecom): catalog — ghi rõ availableQty 2 đường cập nhật (event vs reserve in-txn)\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 7: gap-analysis.md (ghi nhận YAGNI)

**Files:**
- Modify: `overview/gap-analysis.md`

- [ ] **Step 1: Thêm mục "6. YAGNI hoãn" cuối file**

Chèn sau mục "## 5. Report (Báo cáo) — Hạng 5":

```
---

## 6. YAGNI hoãn (ghi nhận, chưa thiết kế)

> Theo [spec ecom-review 2026-06-04](../superpowers/specs/2026-06-04-ecom-review-design.md).

- **Khuyến mãi/voucher/discount (Order):** chưa mô hình hóa; `Order` giữ `subtotal/shippingFee/total`.
- **`shippingFee`:** nguồn tính phí phụ thuộc module **Shipping** (Hạng 1); checkout tạm chưa tự tính.
- **RMA từng phần, partial fulfillment, guest checkout, thuế/VAT:** ngoài phạm vi hiện tại.
```

- [ ] **Step 2: Verify**

Run:
```bash
cd /home/hoaiphuong/code/wms-ecom/docs
grep -n "YAGNI hoãn" overview/gap-analysis.md
grep -ohE '\]\(\.\.?/[^)#]+\.md' overview/gap-analysis.md | sort -u   # link spec hợp lệ
test -f superpowers/specs/2026-06-04-ecom-review-design.md && echo "spec OK"
```
Expected: mục mới xuất hiện; link spec trỏ file tồn tại.

- [ ] **Step 3: Commit**

```bash
git add overview/gap-analysis.md
git commit -m "$(printf 'docs(ecom): gap-analysis — ghi nhận discount/shippingFee YAGNI hoãn\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 8: Verify nhất quán toàn cục & rà link

**Files:** (đọc-only) tất cả file đã sửa

- [ ] **Step 1: Không còn mô tả cũ ở bất kỳ đâu**

Run:
```bash
cd /home/hoaiphuong/code/wms-ecom/docs
grep -rn "WMS giữ tồn (reserved" . --include=*.md            # rỗng
grep -rn "giữ hàng khi chốt đơn" overview/ order/ catalog/   # rỗng
grep -rn "stock.changed{sku,−}" overview/main-flow.md        # rỗng
```
Expected: cả 3 lệnh trả về **rỗng**.

- [ ] **Step 2: Event mới xuất hiện đồng bộ ở các file chính**

Run:
```bash
cd /home/hoaiphuong/code/wms-ecom/docs
grep -rln "order.ready_to_fulfill" overview/data-ownership.md overview/main-flow.md order/use-cases.md order/workflow.md
grep -rln "print.completed" overview/data-ownership.md overview/main-flow.md order/use-cases.md order/workflow.md order/data-model.md
```
Expected: mỗi `grep` liệt kê **đủ** các file tương ứng (không thiếu file nào).

- [ ] **Step 3: Anchor heading vẫn khớp link nội bộ**

Run:
```bash
cd /home/hoaiphuong/code/wms-ecom/docs
grep -n "^## \|^### " overview/data-ownership.md   # đối chiếu slug #chống-oversell-khi-xác-nhận-đơn còn đúng
```
Expected: heading "## Chống oversell khi xác nhận đơn" vẫn tồn tại (slug link tới nó hợp lệ).

- [ ] **Step 4 (không commit — chỉ báo cáo):** Nếu mọi verify pass, tóm tắt kết quả cho người dùng. Nếu fail, quay lại Task tương ứng sửa.

---

## Ghi chú thực thi

- File này **không có test tự động** — verify là grep + đọc đối chiếu. Mỗi Task commit riêng để dễ revert.
- Khi áp dụng Edit: luôn `Read` file trước để lấy đúng chuỗi gốc (nội dung quanh các dòng có thể đã đổi do Task trước).
- Push (nếu cần) theo CLAUDE.md: `GIT_SSH_COMMAND='ssh -o BatchMode=yes' git push git@github.com:pbvm-ecom-warehouse/docs.git main`.
