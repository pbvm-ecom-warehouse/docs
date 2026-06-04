# WMS — Use Cases

## Tổng quan

| # | Tên | Actor | Trạng thái |
|---|---|---|---|
| UC-01 | Tạo Purchase Order | MANAGER | 🔄 Đang phân tích |
| UC-02 | Good Receive Note (GRN) | RECEIVER + MANAGER | 🔄 Đang phân tích |
| UC-03 | Put-away — Sắp xếp vào vị trí | RECEIVER | 🔄 Đang phân tích |
| UC-04 | Lệnh in ly (Make-to-Order) | MANAGER + PRINTER | 🔄 Đang phân tích |
| UC-05 | Xuất kho theo đơn hàng | PICKER | 🔄 Đang phân tích |
| UC-06 | Kiểm kho & Điều chỉnh tồn | COUNTER + MANAGER | 🔄 Đang phân tích |
| UC-07 | Chuyển kho (Stock Transfer) | MANAGER + PICKER + RECEIVER | 🔄 Đang phân tích |
| UC-08 | Hủy hàng hết hạn/hỏng (Scrap) | COUNTER/RECEIVER đề xuất, MANAGER duyệt | 🔄 Đang phân tích |
| UC-09 | Hoàn hàng (Return/RMA) | RECEIVER | 🔄 Đang phân tích |

---

## UC-01: Tạo Purchase Order

**Actor:** MANAGER  
**Mục đích:** Đặt hàng từ nhà cung cấp trước khi hàng về kho  
**Áp dụng cho:** MATERIAL, CUP_BLANK, PACKAGING

### Luồng chính

1. MANAGER tạo PO — chọn nhà cung cấp, danh sách hàng, số lượng, giá dự kiến *(số lượng có thể nhập theo đơn vị phụ như thùng/bao — hệ quy về đơn vị cơ sở khi nhập kho)*
2. PO được xác nhận và gửi/thông báo cho nhà cung cấp
3. Trạng thái PO: `DRAFT` → `CONFIRMED` → `SENT`

### Trạng thái PO

| Status | Mô tả |
|---|---|
| `DRAFT` | Đang soạn, chưa xác nhận |
| `CONFIRMED` | Đã xác nhận nội bộ |
| `SENT` | Đã gửi cho nhà cung cấp |
| `PARTIALLY_RECEIVED` | Nhận một phần hàng |
| `COMPLETED` | Nhận đủ hàng |
| `CANCELLED` | Hủy đơn |

---

## UC-02: Good Receive Note (GRN)

**Actor:** RECEIVER thực hiện, MANAGER duyệt  
**Trigger:** Hàng về theo Purchase Order  
**Áp dụng cho:** MATERIAL, CUP_BLANK, PACKAGING

### Luồng chính

1. RECEIVER tạo GRN — tham chiếu PO tương ứng
2. **Quét barcode** từng mặt hàng → hệ thống khớp đúng dòng PO/GRN *(quét mã lạ/không thuộc PO → cảnh báo, cho chọn hoặc khai báo item)*
3. Nhập số lượng thực tế nhận được từng mặt hàng *(có thể lệch với PO)*. Hàng `isPerishable` → nhập thêm **lotNumber + expiryDate** → hệ tạo `Lot`
4. RECEIVER xác nhận nhận hàng → hệ thống cộng tồn: `StockBalance.onHand +=` và đặt hàng vào **shelf staging** (lớp vị trí) — chờ put-away. *(available tăng → sync Ecommerce, kể cả khi MANAGER chưa duyệt)*
5. Hệ thống cộng dồn `actualQty` vào PO → cập nhật trạng thái PO: thiếu → `PARTIALLY_RECEIVED`, đủ → `COMPLETED`
6. MANAGER duyệt GRN *(bước audit — hàng đã sellable từ bước 4; duyệt có thể song song với put-away)*
7. Nếu lệch PO → ghi nhận chênh lệch, xử lý với nhà cung cấp

### Trạng thái GRN

| Status | Mô tả |
|---|---|
| `DRAFT` | Đang nhập liệu |
| `CONFIRMED` | RECEIVER xác nhận đã nhận hàng |
| `APPROVED` | MANAGER duyệt |

---

## UC-03: Put-away — Sắp xếp vào vị trí

**Actor:** RECEIVER  
**Trigger:** Sau khi GRN **CONFIRMED** (không chờ MANAGER duyệt — duyệt là bước audit song song)  
**Mục đích:** Ghi nhận vị trí lưu trữ thực tế trong kho (Warehouse → Zone → Rack → Shelf)

### Luồng chính

1. Hệ thống sinh danh sách hàng cần sắp xếp từ GRN vừa xác nhận
2. **Quét barcode SKU → quét barcode vị trí (shelf)** → nhập số lượng
3. Hệ thống tự khớp dòng GRN *(sai item hoặc qty lệch → cảnh báo)*
4. Nếu một mặt hàng để nhiều vị trí → tách số lượng theo từng vị trí (quét nhiều shelf)
5. RECEIVER xác nhận put-away → hệ thống **chuyển hàng từ shelf staging → shelf thật** (chỉ đổi lớp vị trí; `onHand` không đổi nên không sync Ecommerce)
6. Khi xuất kho (UC-05) → hệ thống hiển thị vị trí để PICKER lấy đúng chỗ

---

## UC-04: Lệnh in ly (Make-to-Order)

**Actor:** MANAGER tạo lệnh, PRINTER thực hiện  
**Trigger:** Sự kiện `print.requested` từ Ecommerce (đơn ly-in đã `PAID`) — xem [data-ownership](../overview/data-ownership.md)  
**Đặc điểm:** In tại chỗ (in-house), không thuê ngoài. **CUP_PRINTED per-design** — mỗi mẫu in là 1 SKU riêng.

> **Đặt hàng ly in (make-to-order) & reserve — chuỗi hold `reserved`:** khi khách đặt một design,
> - Nếu SKU CUP_PRINTED của design đó **đã có tồn** (`available ≥ qty`, vd lần trước in dư) → reserve CUP_PRINTED như hàng thường, **không cần lệnh in**.
> - Nếu **thiếu** → mở **PrintJob** (make-to-order); chính việc mở PrintJob **giữ (`reserved`) CUP_BLANK 1 lần** cho phần thiếu — **không reserve lại** (đây là hold của đơn). Ràng buộc chống oversell ở khâu này là **tồn ly trắng**, không phải ly in.
> - In xong, **hold chuyển** từ CUP_BLANK (đã tiêu thụ) sang **`CUP_PRINTED.reserved` cho đúng đơn** → UC-05 xuất trên printed như hàng thường.

### Luồng chính

1. MANAGER tạo lệnh in — chọn ly nền (CUP_BLANK), design (→ SKU CUP_PRINTED đầu ra, tạo mới item nếu design chưa có), số lượng, file design, tham chiếu đơn hàng
2. Hệ thống kiểm tra tồn CUP_BLANK đủ không → **giữ (`reserved`) CUP_BLANK** cho lệnh in 1 lần (PENDING) *(blank `available` giảm → bắn `stock.changed` cho blank)*
3. Bắt đầu in: PRINTER **quét barcode SKU + quét shelf** lấy CUP_BLANK → hệ trừ tồn thật `CUP_BLANK onHand−=, reserved−=` (`PRINT_CONSUME`), Job → `IN_PROGRESS` *(blank `available` không đổi → không bắn event)*
4. In xong → PRINTER xác nhận nhập kho CUP_PRINTED *(hệ sinh/in tem barcode cho item CUP_PRINTED để put-away như hàng thường)*
5. Hệ thống `CUP_PRINTED onHand+=` **và `reserved+=` giữ cho đúng đơn** (`PRINT_OUTPUT`), Job → `COMPLETED` *(printed `available` không đổi → không bắn event printed; nếu in vào kho không gắn đơn thì không reserve → có bắn)*

### Trạng thái Print Job

| Status | Mô tả |
|---|---|
| `PENDING` | Chờ thực hiện |
| `IN_PROGRESS` | Đang in |
| `COMPLETED` | In xong, đã nhập kho CUP_PRINTED |
| `CANCELLED` | Hủy lệnh in |

---

## UC-05: Xuất kho theo đơn hàng

**Actor:** PICKER thực hiện  
**Trigger:** Sự kiện `order.ready_to_fulfill` (Ecom→WMS) khi đơn vào `fulfillmentStatus = READY_TO_PICK`  
**Áp dụng cho:** Tất cả loại hàng (MATERIAL, CUP_BLANK, CUP_PRINTED, PACKAGING)

> Tồn đã được **giữ (`reserved`) từ lúc khách đặt** (atomic trong transaction checkout, không phải qua event) ở kho được phân bổ (ưu tiên CENTRAL); phiếu xuất chỉ sinh khi đơn vào `fulfillmentStatus = READY_TO_PICK` (Ecom phát `order.ready_to_fulfill`) — với đơn ly-in là sau khi in xong mọi ly-in, không chỉ khi `CONFIRMED`. Khâu này chỉ hiện thực hóa: lấy hàng & trừ tồn thật. *(Với ly-in make-to-order, hold đã **chuyển sang CUP_PRINTED** sau khi in xong (UC-04) → UC-05 xử lý đồng nhất qua `reserved`.)*

### Luồng chính

1. Hệ thống sinh phiếu xuất kho khi nhận `order.ready_to_fulfill` (đơn ở `READY_TO_PICK`)
2. Kiểm tra tồn kho từng mặt hàng — cảnh báo nếu không đủ
3. Hệ thống hiển thị vị trí (Zone/Rack/Shelf) của từng mặt hàng. Hàng `isPerishable` → **gợi ý lô hết hạn sớm nhất (FEFO)**; PICKER được chọn lô khác (ghi đè). Lô đã `EXPIRED` không được xuất bán
4. PICKER tới vị trí gợi ý → **quét barcode SKU + quét shelf** để xác nhận đúng món, đúng chỗ *(quét sai → cảnh báo)*
5. PICKER chuẩn bị hàng, đóng gói
6. PICKER xác nhận xuất kho → `InventoryStock` (shelf) `−=`, `StockBalance.onHand −=` và `reserved −=` *(available không đổi)*
7. Trạng thái đơn hàng cập nhật → `Đã xuất kho`

---

## UC-06: Kiểm kho & Điều chỉnh tồn

**Actor:** COUNTER kiểm đếm, MANAGER duyệt  
**Tần suất:** Định kỳ hoặc đột xuất  
**Phạm vi:** Có thể kiểm toàn bộ kho hoặc từng Zone/loại hàng

### Luồng chính

1. MANAGER tạo phiếu kiểm kho — chọn phạm vi kiểm (kho, zone, loại hàng)
2. COUNTER kiểm đếm thực tế từng sản phẩm, nhập số lượng vào hệ thống
3. Hệ thống so sánh: **tồn thực tế vs tồn hệ thống** → hiển thị chênh lệch
4. MANAGER duyệt điều chỉnh + ghi lý do *(hư hỏng, mất mát, nhập nhầm...)*
5. Hệ thống cập nhật tồn kho theo số thực tế

---

## UC-07: Chuyển kho (Stock Transfer)

**Actor:** MANAGER tạo/duyệt, PICKER xuất tại nguồn, RECEIVER nhận tại đích  
**Áp dụng:** Mọi chiều — Trung tâm ↔ Phụ, Phụ ↔ Phụ

### Luồng chính

1. MANAGER tạo lệnh chuyển kho — chọn kho nguồn, kho đích, danh sách hàng + số lượng
2. Hệ thống kiểm tra tồn kho nguồn đủ không → MANAGER xác nhận (`CONFIRMED`) → **reserve tại kho nguồn** (`reserved += qty`) để không bán phần chờ chuyển *(available nguồn giảm → bắn `stock.changed` delta−)*
3. PICKER chuẩn bị hàng tại kho nguồn → xác nhận xuất → `onHand−=, reserved−=` tại nguồn (`TRANSFER_OUT`), Transfer → `IN_TRANSIT` *(available không đổi ở bước này — đã giảm từ lúc reserve)*
4. RECEIVER xác nhận hàng đến kho đích → chỉ định vị trí (Zone/Rack/Shelf) → `onHand+=` tại đích (`TRANSFER_IN`), Transfer → `COMPLETED` *(available đích tăng → bắn `stock.changed` delta+)*
5. MANAGER duyệt hoàn tất

> **Tồn trong lúc transit:** `available` tổng (gộp mọi kho) **giảm tạm** từ lúc reserve nguồn (`CONFIRMED`) đến khi nhận đích (`TRANSFER_IN`) — phản ánh đúng việc hàng đang trên đường, chưa giao ngay được. Trọn vòng (OUT + IN) net = 0.

### Trạng thái Transfer

| Status | Mô tả |
|---|---|
| `DRAFT` | Đang soạn |
| `CONFIRMED` | MANAGER xác nhận lệnh |
| `IN_TRANSIT` | Hàng đang trên đường chuyển |
| `COMPLETED` | Đã nhận tại kho đích |
| `CANCELLED` | Hủy lệnh chuyển |

---

## UC-08: Hủy hàng hết hạn/hỏng (Scrap)

**Actor:** COUNTER/RECEIVER đề xuất, MANAGER duyệt  
**Trigger:** Lô hết hạn (job tự đánh dấu `EXPIRED`) hoặc phát hiện hàng hỏng/vỡ  
**Mục đích:** Ghi giảm tồn hợp lệ, có lý do — không để hàng không bán được nằm trong `available`

### Luồng chính

1. Hệ thống liệt kê lô `EXPIRED` (và phần `expired` trong StockBalance) hoặc người vận hành tạo đề xuất hủy hàng hỏng
2. Chọn item/lô + số lượng + **lý do** (hết hạn, vỡ, ẩm mốc...)
3. MANAGER duyệt
4. Hệ thống: `InventoryStock` (shelf+lô) `−=`, `StockBalance.onHand −=` và `expired −=` *(available không đổi — hàng hết hạn vốn đã ngoài available)*

### Trạng thái Scrap

| Status | Mô tả |
|---|---|
| `DRAFT` | Đề xuất hủy |
| `APPROVED` | MANAGER duyệt, đã ghi giảm tồn |
| `REJECTED` | Không duyệt |

---

## UC-09: Hoàn hàng (Return / RMA)

**Actor:** RECEIVER  
**Trigger:** Khách trả hàng (sự kiện `order.returned` từ Ecommerce hoặc lập tay)  
**Mục đích:** Nhập lại hàng tốt vào kho, tách hàng hỏng đi hủy

### Luồng chính

1. RECEIVER tạo phiếu hoàn — tham chiếu đơn gốc, quét barcode hàng trả
2. **Kiểm tra tình trạng** từng món → `GOOD` hoặc `DAMAGED`
3. Hàng `GOOD` → nhập lại kho (quét shelf): `StockBalance.onHand +=`, `InventoryStock +=` *(available tăng → sync Ecommerce)*
4. Hàng `DAMAGED` → chuyển sang **UC-08 Scrap** (không nhập kho)
5. Hàng `isPerishable` → cần lô + hạn còn hợp lệ mới được nhập lại

### Trạng thái GoodsReturn

| Status | Mô tả |
|---|---|
| `DRAFT` | Đang lập phiếu |
| `INSPECTED` | Đã phân loại GOOD/DAMAGED |
| `RESTOCKED` | Đã nhập lại hàng tốt |
| `CANCELLED` | Hủy phiếu |

---

## Hủy đơn (release tồn đã giữ)

> Không phải UC độc lập — xử lý qua sự kiện. Khi đơn bị hủy **trước khi xuất kho** (`order.cancelled` từ Ecommerce): WMS trả lại tồn đã giữ — `StockBalance.reserved −=` → `available` tăng → sync Ecommerce. Nếu đơn **đã xuất kho** thì dùng UC-09 (hoàn hàng) thay vì hủy.
