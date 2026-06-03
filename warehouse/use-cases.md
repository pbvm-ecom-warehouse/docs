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

---

## UC-01: Tạo Purchase Order

**Actor:** MANAGER  
**Mục đích:** Đặt hàng từ nhà cung cấp trước khi hàng về kho  
**Áp dụng cho:** MATERIAL, CUP_BLANK, PACKAGING

### Luồng chính

1. MANAGER tạo PO — chọn nhà cung cấp, danh sách hàng, số lượng, giá dự kiến
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
4. RECEIVER xác nhận nhận hàng → hệ thống cộng tồn: `StockBalance.onHand +=` và đặt hàng vào **shelf staging** (lớp vị trí) — chờ put-away
5. MANAGER duyệt GRN
5. Nếu lệch PO → ghi nhận chênh lệch, xử lý với nhà cung cấp

### Trạng thái GRN

| Status | Mô tả |
|---|---|
| `DRAFT` | Đang nhập liệu |
| `CONFIRMED` | RECEIVER xác nhận đã nhận hàng |
| `APPROVED` | MANAGER duyệt |

---

## UC-03: Put-away — Sắp xếp vào vị trí

**Actor:** RECEIVER  
**Trigger:** Sau khi GRN được xác nhận  
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
**Trigger:** Có đơn hàng khách đặt ly in logo/design riêng  
**Đặc điểm:** In tại chỗ (in-house), không thuê ngoài

### Luồng chính

1. MANAGER tạo lệnh in — chọn loại ly (CUP_BLANK), số lượng, file design, tham chiếu đơn hàng
2. Hệ thống kiểm tra tồn kho CUP_BLANK có đủ không
3. Xuất CUP_BLANK khỏi kho → đưa vào máy in *(hệ thống trừ tồn CUP_BLANK)*
4. In xong → PRINTER xác nhận nhập kho CUP_PRINTED *(hệ sinh/in tem barcode cho item CUP_PRINTED để put-away như hàng thường)*
5. Hệ thống cộng tồn kho CUP_PRINTED

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
**Trigger:** Đơn hàng được xác nhận, cần xuất hàng giao cho khách  
**Áp dụng cho:** Tất cả loại hàng (MATERIAL, CUP_BLANK, CUP_PRINTED, PACKAGING)

> Tồn đã được **giữ (`reserved`) từ lúc chốt đơn** ở kho được phân bổ (ưu tiên CENTRAL). Khâu này chỉ hiện thực hóa: lấy hàng & trừ tồn thật.

### Luồng chính

1. Hệ thống sinh phiếu xuất kho từ đơn hàng đã xác nhận
2. Kiểm tra tồn kho từng mặt hàng — cảnh báo nếu không đủ
3. Hệ thống hiển thị vị trí (Zone/Rack/Shelf) của từng mặt hàng. Hàng `isPerishable` → **gợi ý lô hết hạn sớm nhất (FEFO)**; PICKER được chọn lô khác (ghi đè). Lô đã `EXPIRED` không được xuất bán
4. PICKER tới vị trí gợi ý → **quét barcode SKU + quét shelf** để xác nhận đúng món, đúng chỗ *(quét sai → cảnh báo)*
5. PICKER chuẩn bị hàng, đóng gói
6. PICKER xác nhận xuất kho → `InventoryStock` (shelf) `−=`, `StockBalance.onHand −=` và `reserved −=` *(available không đổi)*
6. Trạng thái đơn hàng cập nhật → `Đã xuất kho`

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
2. Hệ thống kiểm tra tồn kho nguồn có đủ không
3. PICKER chuẩn bị hàng tại kho nguồn → xác nhận xuất
4. RECEIVER xác nhận hàng đến kho đích → chỉ định vị trí (Zone/Rack/Shelf)
5. Hệ thống: trừ tồn kho nguồn, cộng tồn kho đích
6. MANAGER duyệt hoàn tất

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
