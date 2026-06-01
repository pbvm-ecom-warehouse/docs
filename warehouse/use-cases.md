# WMS — Use Cases

## Tổng quan

| # | Tên | Actor | Trạng thái |
|---|---|---|---|
| UC-01 | Tạo Purchase Order | MANAGER | 🔄 Đang phân tích |
| UC-02 | Good Receive Note (GRN) | STAFF + MANAGER | 🔄 Đang phân tích |
| UC-03 | Put-away — Sắp xếp vào vị trí | STAFF | 🔄 Đang phân tích |
| UC-04 | Lệnh in ly (Make-to-Order) | MANAGER | 🔄 Đang phân tích |
| UC-05 | Xuất kho theo đơn hàng | STAFF | 🔄 Đang phân tích |
| UC-06 | Kiểm kho & Điều chỉnh tồn | STAFF + MANAGER | 🔄 Đang phân tích |
| UC-07 | Chuyển kho (Stock Transfer) | STAFF + MANAGER | 🔄 Đang phân tích |

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

**Actor:** STAFF thực hiện, MANAGER duyệt  
**Trigger:** Hàng về theo Purchase Order  
**Áp dụng cho:** MATERIAL, CUP_BLANK, PACKAGING

### Luồng chính

1. STAFF tạo GRN — tham chiếu PO tương ứng
2. Nhập số lượng thực tế nhận được từng mặt hàng *(có thể lệch với PO)*
3. STAFF xác nhận nhận hàng → hệ thống cộng tồn kho
4. MANAGER duyệt GRN
5. Nếu lệch PO → ghi nhận chênh lệch, xử lý với nhà cung cấp

### Trạng thái GRN

| Status | Mô tả |
|---|---|
| `DRAFT` | Đang nhập liệu |
| `CONFIRMED` | STAFF xác nhận đã nhận hàng |
| `APPROVED` | MANAGER duyệt |

---

## UC-03: Put-away — Sắp xếp vào vị trí

**Actor:** STAFF  
**Trigger:** Sau khi GRN được xác nhận  
**Mục đích:** Ghi nhận vị trí lưu trữ thực tế trong kho (Warehouse → Zone → Rack → Shelf)

### Luồng chính

1. Hệ thống sinh danh sách hàng cần sắp xếp từ GRN vừa xác nhận
2. STAFF chọn từng mặt hàng → chỉ định vị trí: **Zone → Rack → Shelf**
3. Nếu một mặt hàng để nhiều vị trí → tách số lượng theo từng vị trí
4. STAFF xác nhận put-away → hệ thống lưu vị trí tồn kho
5. Khi xuất kho (UC-05) → hệ thống hiển thị vị trí để STAFF lấy đúng chỗ

---

## UC-04: Lệnh in ly (Make-to-Order)

**Actor:** MANAGER  
**Trigger:** Có đơn hàng khách đặt ly in logo/design riêng  
**Đặc điểm:** In tại chỗ (in-house), không thuê ngoài

### Luồng chính

1. MANAGER tạo lệnh in — chọn loại ly (CUP_BLANK), số lượng, file design, tham chiếu đơn hàng
2. Hệ thống kiểm tra tồn kho CUP_BLANK có đủ không
3. Xuất CUP_BLANK khỏi kho → đưa vào máy in *(hệ thống trừ tồn CUP_BLANK)*
4. In xong → STAFF xác nhận nhập kho CUP_PRINTED
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

**Actor:** STAFF thực hiện  
**Trigger:** Đơn hàng được xác nhận, cần xuất hàng giao cho khách  
**Áp dụng cho:** Tất cả loại hàng (MATERIAL, CUP_BLANK, CUP_PRINTED, PACKAGING)

### Luồng chính

1. Hệ thống sinh phiếu xuất kho từ đơn hàng đã xác nhận
2. Kiểm tra tồn kho từng mặt hàng — cảnh báo nếu không đủ
3. Hệ thống hiển thị vị trí (Zone/Rack/Shelf) của từng mặt hàng
4. STAFF chuẩn bị hàng, đóng gói
5. STAFF xác nhận xuất kho → hệ thống trừ tồn kho
6. Trạng thái đơn hàng cập nhật → `Đã xuất kho`

---

## UC-06: Kiểm kho & Điều chỉnh tồn

**Actor:** STAFF kiểm đếm, MANAGER duyệt  
**Tần suất:** Định kỳ hoặc đột xuất  
**Phạm vi:** Có thể kiểm toàn bộ kho hoặc từng Zone/loại hàng

### Luồng chính

1. MANAGER tạo phiếu kiểm kho — chọn phạm vi kiểm (kho, zone, loại hàng)
2. STAFF kiểm đếm thực tế từng sản phẩm, nhập số lượng vào hệ thống
3. Hệ thống so sánh: **tồn thực tế vs tồn hệ thống** → hiển thị chênh lệch
4. MANAGER duyệt điều chỉnh + ghi lý do *(hư hỏng, mất mát, nhập nhầm...)*
5. Hệ thống cập nhật tồn kho theo số thực tế

---

## UC-07: Chuyển kho (Stock Transfer)

**Actor:** MANAGER tạo/duyệt, STAFF thực hiện  
**Áp dụng:** Mọi chiều — Trung tâm ↔ Phụ, Phụ ↔ Phụ

### Luồng chính

1. MANAGER tạo lệnh chuyển kho — chọn kho nguồn, kho đích, danh sách hàng + số lượng
2. Hệ thống kiểm tra tồn kho nguồn có đủ không
3. STAFF chuẩn bị hàng tại kho nguồn → xác nhận xuất
4. STAFF xác nhận hàng đến kho đích → chỉ định vị trí (Zone/Rack/Shelf)
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
