# Gợi ý vị trí put-away theo kích thước — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bổ sung mô tả tài liệu cho tính năng gợi ý shelf khi put-away dựa trên kích thước kệ & mặt hàng (output: "shelf còn chứa được N đơn vị").

**Architecture:** Đây là repo tài liệu — không có code/test. Mỗi task sửa 1 file `.md`. "Verify" = grep kiểm tra anchor & link phân giải đúng và nhất quán xuyên file (theo CLAUDE.md). Nguồn chuẩn: [spec](../specs/2026-06-08-shelf-putaway-recommendation-design.md).

**Tech Stack:** Markdown tiếng Việt; quy ước anchor GitHub tiếng Việt (giữ dấu); commit prefix `docs(warehouse):`.

**Phạm vi file:**
- `warehouse/data-model.md` — thêm field Shelf + WarehouseItem + ghi chú dẫn xuất.
- `warehouse/use-cases.md` — UC-03 thêm bước hệ gợi ý vị trí.
- `warehouse/workflow.md` — chèn bước "Gợi ý vị trí" vào WF-01.
- **Không** đụng `data-ownership.md`/`system-context.md`: không thêm collection/enum/event mới (chỉ thêm field; `fillFactor` là cấu hình, không phải enum).

---

### Task 1: Data-model — kích thước Shelf

**Files:**
- Modify: `warehouse/data-model.md` — bảng **Shelf** (quanh dòng 41–49)

- [ ] **Step 1: Thêm field kích thước vào bảng Shelf**

Trong bảng `### Shelf (Tầng trong rack)`, thêm 4 dòng **trước** dòng `isStaging`:

```markdown
| innerDepth | Number | Chiều sâu **lòng** tầng (cm) — tùy chọn, cần để gợi ý put-away |
| innerWidth | Number | Chiều rộng lòng tầng (cm) — tùy chọn |
| innerHeight | Number | Chiều cao khoảng tầng (cm) — tùy chọn |
| fillFactor | Number | Hệ số lấp đầy riêng shelf (0–1), override mặc định hệ thống — tùy chọn |
```

- [ ] **Step 2: Thêm ghi chú dẫn xuất usableVolume**

Ngay sau bảng Shelf (sau dòng `isStaging`, trước `---`), thêm blockquote:

```markdown
> **Sức chứa (cho gợi ý put-away):** `usableVolume = innerDepth × innerWidth × innerHeight` (cm³, dẫn xuất — không lưu). Shelf `isStaging` không cần kích thước (không bao giờ là đích gợi ý). `fillFactor` mặc định ở mức cấu hình hệ thống (vd `0.75`); shelf chỉ khai khi muốn ghi đè. Kích thước **tùy chọn**: shelf chưa khai → bỏ khỏi danh sách gợi ý. Xem [workflow.md → WF-01 Gợi ý vị trí](workflow.md#wf-01-nhập-hàng-từ-nhà-cung-cấp-uc-01--uc-02--uc-03).
```

- [ ] **Step 3: Verify anchor đích tồn tại**

Run: `grep -n "^## WF-01" warehouse/workflow.md`
Expected: in ra dòng `## WF-01: Nhập hàng từ nhà cung cấp (UC-01 + UC-02 + UC-03)` (xác nhận anchor `#wf-01-nhập-hàng-từ-nhà-cung-cấp-uc-01--uc-02--uc-03` phân giải — lưu ý `(` `)` `+` bị bỏ, tạo `--`).

- [ ] **Step 4: Commit**

```bash
git add warehouse/data-model.md
git commit -m "docs(warehouse): thêm kích thước Shelf cho gợi ý put-away

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Data-model — kích thước WarehouseItem

**Files:**
- Modify: `warehouse/data-model.md` — bảng **WarehouseItem** (quanh dòng 61–74)

- [ ] **Step 1: Thêm field kích thước vào bảng WarehouseItem**

Trong bảng `### WarehouseItem`, thêm 3 dòng **trước** dòng `isActive`:

```markdown
| depth | Number | Chiều sâu **1 đơn vị cơ sở** (cm) — tùy chọn, cần để gợi ý put-away |
| width | Number | Chiều rộng 1 đơn vị cơ sở (cm) — tùy chọn |
| height | Number | Chiều cao 1 đơn vị cơ sở (cm) — tùy chọn |
```

- [ ] **Step 2: Thêm ghi chú dẫn xuất unitVolume**

Ngay sau bảng `**attributes[]**` (heading con của WarehouseItem), thêm blockquote — đặt trước mục `**Quy ước sinh SKU**`:

```markdown
> **Thể tích đơn vị (cho gợi ý put-away):** `unitVolume = depth × width × height` (cm³, dẫn xuất). Khai lúc khai báo item, dùng lại cho mọi GRN. **Không** dùng cân nặng. Thiếu kích thước → item không được gợi ý vị trí, RECEIVER put-away nhập tay.
```

- [ ] **Step 3: Verify cấu trúc bảng còn nguyên**

Run: `grep -n "^| depth\|^| width\|^| height\|unitVolume\|innerDepth\|usableVolume" warehouse/data-model.md`
Expected: in ra đủ các dòng field mới + 2 ghi chú dẫn xuất (Task 1 & 2).

- [ ] **Step 4: Commit**

```bash
git add warehouse/data-model.md
git commit -m "docs(warehouse): thêm kích thước WarehouseItem cho gợi ý put-away

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Use-case — UC-03 thêm bước gợi ý

**Files:**
- Modify: `warehouse/use-cases.md` — `## UC-03: Put-away` (dòng 70–83)

- [ ] **Step 1: Chèn bước gợi ý vào Luồng chính UC-03**

Thay block "Luồng chính" hiện tại (các bước 1–6) bằng bản có thêm bước gợi ý. Cụ thể, chèn **bước mới sau bước 1** và đánh số lại:

```markdown
1. Hệ thống sinh danh sách hàng cần sắp xếp từ GRN vừa xác nhận
2. **Gợi ý vị trí (advisory):** với item đã khai kích thước, hệ liệt kê các shelf phù hợp kèm **sức chứa còn lại** (`còn chứa được ~N đơn vị`) — ưu tiên shelf đã có cùng SKU (gom chỗ), rồi **best-fit** (lấp khít, chừa kệ rộng cho hàng to). Item/shelf chưa khai kích thước → bỏ qua gợi ý, làm thủ công. Chi tiết cách tính: [workflow.md → WF-01](workflow.md#wf-01-nhập-hàng-từ-nhà-cung-cấp-uc-01--uc-02--uc-03)
3. **Quét barcode SKU → quét barcode vị trí (shelf)** → nhập số lượng *(RECEIVER được đặt khác gợi ý; gợi ý không cưỡng chế)*
4. Hệ thống tự khớp dòng GRN *(sai item hoặc qty lệch → cảnh báo)*
5. Nếu một mặt hàng để nhiều vị trí → tách số lượng theo từng vị trí (quét nhiều shelf)
6. RECEIVER xác nhận put-away → hệ thống **chuyển hàng từ shelf staging → shelf thật** (chỉ đổi lớp vị trí; `onHand` không đổi nên không sync Ecommerce)
7. Khi xuất kho (UC-05) → hệ thống hiển thị vị trí để PICKER lấy đúng chỗ
```

- [ ] **Step 2: Verify link & đánh số**

Run: `grep -n "Gợi ý vị trí\|còn chứa được\|wf-01-nhập-hàng" warehouse/use-cases.md`
Expected: in ra bước 2 mới + link WF-01. Kiểm mắt: các bước UC-03 đánh số liên tục 1→7.

- [ ] **Step 3: Commit**

```bash
git add warehouse/use-cases.md
git commit -m "docs(warehouse): UC-03 thêm bước gợi ý vị trí put-away

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Workflow — WF-01 mô tả thuật toán gợi ý

**Files:**
- Modify: `warehouse/workflow.md` — sau sơ đồ WF-01 (sau dòng 51, trước `---` dòng 53)

- [ ] **Step 1: Thêm blockquote mô tả thuật toán gợi ý**

Chèn ngay sau blockquote "GRN `CONFIRMED` cũng cập nhật trạng thái PO..." (dòng 51), trước `---`:

```markdown
> **Gợi ý vị trí put-away (advisory, theo kích thước):** với item `I` đã khai `unitVolume`, số lượng `Q`, trong kho `W` — hệ duyệt mọi shelf non-staging đã khai kích thước:
> 1. **Ràng buộc 3 chiều (cho xoay 90°):** sắp giảm dần 3 chiều của `I` và shelf; yêu cầu `I[i] ≤ shelf[i]` mọi chiều — trượt thì loại (hàng quá to/dài không lọt tầng).
> 2. **Đã chiếm** = `Σ (quantity × unitVolume)` mọi `InventoryStock` trên shelf (mọi SKU & lô) — tính **động** từ tồn thật, không lưu trường riêng.
> 3. **Còn trống** = `usableVolume × fillFactor − đã chiếm`; **sức chứa** = `floor(còn trống ÷ I.unitVolume)`.
> 4. **Xếp hạng:** ưu tiên shelf đã chứa cùng SKU (đủ `Q`) → rồi **best-fit** (còn trống nhỏ nhất mà vẫn đủ `Q`). Không shelf đơn nào đủ `Q` → gợi ý tổ hợp nhiều shelf (`A: 30, B: 20`).
> 5. **Output:** `[mã shelf — còn chứa được N đơn vị]`; RECEIVER vẫn quét SKU + shelf để xác nhận, được đặt khác gợi ý. Hàng vượt mọi shelf → cảnh báo, xử lý thủ công.
>
> Định nghĩa field & dẫn xuất `usableVolume`/`unitVolume`: [data-model.md → Cấu trúc kho](data-model.md#nhóm-1-cấu-trúc-kho--vị-trí).
```

- [ ] **Step 2: Verify anchor data-model đích tồn tại**

Run: `grep -n "^## Nhóm 1" warehouse/data-model.md`
Expected: in ra `## Nhóm 1: Cấu trúc kho & vị trí` (xác nhận anchor `#nhóm-1-cấu-trúc-kho--vị-trí` — `&` bị bỏ giữa 2 khoảng trắng tạo `--`).

- [ ] **Step 3: Verify nhất quán xuyên file (3 file)**

Run: `grep -rn "fillFactor\|best-fit\|còn chứa được\|usableVolume\|unitVolume" warehouse/`
Expected: thuật ngữ xuất hiện khớp nhau ở data-model.md, use-cases.md, workflow.md — không mâu thuẫn (vd `fillFactor`, `usableVolume`, `unitVolume` viết giống nhau mọi nơi).

- [ ] **Step 4: Commit**

```bash
git add warehouse/workflow.md
git commit -m "docs(warehouse): WF-01 mô tả thuật toán gợi ý vị trí put-away

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Rà link & anchor toàn cục

**Files:** không sửa nội dung — chỉ kiểm tra; sửa nếu phát hiện lệch.

- [ ] **Step 1: Liệt kê mọi link .md nội bộ vừa thêm và đối chiếu file tồn tại**

Run: `grep -ohE '\]\((data-model|use-cases|workflow)\.md' warehouse/*.md | sort -u`
Expected: chỉ trỏ tới 3 file tồn tại trong `warehouse/`.

- [ ] **Step 2: Đối chiếu mọi anchor link tới heading thật**

Run: `grep -n "^## " warehouse/workflow.md warehouse/data-model.md`
Expected: tồn tại heading khớp slug đã link ở Task 1 (`WF-01...`) và Task 4 (`Nhóm 1...`). Nếu lệch slug → sửa link cho khớp rồi commit lại file tương ứng.

- [ ] **Step 3: Commit (chỉ khi có sửa)**

```bash
git add -A warehouse/
git commit -m "docs(warehouse): rà link/anchor tính năng gợi ý put-away

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review (đã chạy)

- **Spec coverage:** field Shelf (T1) ✓, field WarehouseItem (T2) ✓, thuật toán + ràng buộc 3 chiều + best-fit + tổ hợp shelf (T4) ✓, advisory/edge cases (T3+T4) ✓, tính động từ InventoryStock (T4 step 1) ✓, bỏ cân nặng (T2) ✓, fillFactor cấu hình (T1) ✓.
- **Placeholder scan:** không có TBD/TODO — mọi step có nội dung markdown thật.
- **Type consistency:** thuật ngữ thống nhất mọi task — `innerDepth/innerWidth/innerHeight`, `usableVolume`, `depth/width/height`, `unitVolume`, `fillFactor`, "còn chứa được N đơn vị" (T4 step 3 verify chính điều này).
- **Out-of-scope confirm:** không đụng data-ownership.md/system-context.md (không có collection/enum/event mới).
