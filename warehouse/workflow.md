# WMS — Workflow

> Trạng thái: 🔄 Đang phân tích — có thể còn điều chỉnh

## Luồng tổng quan

```
Nhà cung cấp → [UC-01 PO] → [UC-02 GRN] → [UC-03 Put-away] → Kho
                                                                  ↓
                                                          [UC-04 In ly]
                                                                  ↓
Khách hàng  ←  [UC-05 Xuất kho]  ←  Kho
                                      ↕
                              [UC-06 Kiểm kho]
                              [UC-07 Chuyển kho]
```

---

## WF-01: Nhập hàng từ nhà cung cấp (UC-01 + UC-02 + UC-03)

```
MANAGER                    RECEIVER                  Hệ thống
   |                          |                           |
   |-- Tạo PO --------------->|                           |
   |   (chọn NCC, hàng, qty)  |                           |
   |                          |                    Lưu PO (DRAFT)
   |-- Xác nhận PO ---------->|                    PO → CONFIRMED
   |                          |                    PO → SENT
   |                          |                           |
   |        [ Hàng về từ NCC ]                            |
   |                          |                           |
   |                          |-- Tạo GRN (ref PO) ------>|
   |                          |   Nhập qty thực tế        |
   |                          |-- Xác nhận nhận hàng ---->|
   |                          |                    Tồn kho +
   |                          |                    GRN → CONFIRMED
   |-- Duyệt GRN ------------>|                    GRN → APPROVED
   |                          |                           |
   |                          |-- Thực hiện Put-away ---->|
   |                          |   (Zone → Rack → Shelf)   |
   |                          |-- Xác nhận vị trí ------->|
   |                          |                    Lưu vị trí tồn kho
```

---

## WF-02: Lệnh in ly theo đơn hàng (UC-04)

```
MANAGER                    PRINTER                   Hệ thống
   |                          |                           |
   |-- Tạo Print Job -------->|                    Kiểm tồn CUP_BLANK
   |   (loại ly, qty, design) |                    Nếu đủ: tiếp tục
   |                          |                    Nếu thiếu: cảnh báo
   |                          |                           |
   |                          |                    Trừ tồn CUP_BLANK
   |                          |                    Job → IN_PROGRESS
   |                          |                           |
   |       [ Thực hiện in ]                               |
   |                          |                           |
   |                          |-- Xác nhận in xong ------>|
   |                          |   Nhập CUP_PRINTED        |
   |                          |                    Cộng tồn CUP_PRINTED
   |                          |                    Job → COMPLETED
```

---

## WF-03: Xuất kho theo đơn hàng (UC-05)

```
Hệ thống (Order)           PICKER                    Hệ thống (WMS)
   |                          |                           |
   |-- Đơn hàng confirmed --->|                           |
   |   Sinh phiếu xuất kho    |                    Kiểm tồn kho
   |                          |                    Hiển thị vị trí
   |                          |                    (Zone/Rack/Shelf)
   |                          |                           |
   |                          |-- Chuẩn bị hàng -------->|
   |                          |-- Xác nhận xuất kho ----->|
   |                          |                    Trừ tồn kho
   |                          |                    GoodsIssue → CONFIRMED
   |                          |                    Order → Đã xuất kho
```

---

## WF-04: Kiểm kho & Điều chỉnh tồn (UC-06)

```
MANAGER                    COUNTER                   Hệ thống
   |                          |                           |
   |-- Tạo phiếu kiểm kho --->|                    Sinh danh sách
   |   (chọn phạm vi)         |                    hàng cần kiểm
   |                          |                    StockCount → IN_PROGRESS
   |                          |-- Kiểm đếm thực tế ------>|
   |                          |   Nhập qty thực tế        |
   |                          |                    So sánh: thực tế vs hệ thống
   |                          |                    Hiển thị delta
   |                          |                           |
   |-- Xem kết quả ---------->|                           |
   |-- Duyệt điều chỉnh ----->|                    Cập nhật tồn kho
   |   + ghi lý do            |                    StockCount → APPROVED
```

---

## WF-05: Chuyển kho (UC-07)

> Cột giữa gồm 2 role: **PICKER** xuất tại kho nguồn, **RECEIVER** nhận tại kho đích.

```
MANAGER                 PICKER / RECEIVER            Hệ thống
   |                          |                           |
   |-- Tạo lệnh chuyển kho -->|                    Kiểm tồn kho nguồn
   |   (kho nguồn → đích,     |                    Nếu đủ: tiếp tục
   |    danh sách hàng)       |                    Transfer → CONFIRMED
   |                          |                           |
   |             [PICKER]     |-- Chuẩn bị tại kho nguồn->|
   |             [PICKER]     |-- Xác nhận xuất --------->|
   |                          |                    Trừ tồn kho nguồn
   |                          |                    Transfer → IN_TRANSIT
   |                          |                           |
   |       [ Vận chuyển đến kho đích ]                    |
   |                          |                           |
   |           [RECEIVER]     |-- Xác nhận nhận tại đích->|
   |           [RECEIVER]     |   Chỉ định vị trí         |
   |                          |                    Cộng tồn kho đích
   |                          |                    Transfer → COMPLETED
   |-- Duyệt hoàn tất ------->|                           |
```
