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

> **Định danh bằng barcode:** ở các bước chạm hàng vật lý — nhận hàng (WF-01 GRN), put-away, xuất kho (WF-03), chuyển kho (WF-05) — thao tác chuẩn là **quét barcode SKU + quét barcode vị trí (shelf)** rồi mới xác nhận. Hệ tự khớp dòng chứng từ; quét sai item/vị trí hoặc lệch qty → cảnh báo.

> **Lô & hạn dùng (hàng `isPerishable`):** GRN nhập **lotNumber + expiryDate**; xuất kho gợi ý **FEFO** (lô hết hạn sớm nhất trước, cho ghi đè). Job định kỳ đánh dấu lô tới hạn → loại khỏi `available`, chờ **hủy hàng (UC-08 Scrap)**.

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

> **Put-away kích hoạt ngay khi GRN `CONFIRMED`** (đã cộng `onHand`, hàng sellable). MANAGER duyệt (`APPROVED`) là bước **audit**, có thể chạy **song song** với put-away — không chặn put-away. Sơ đồ vẽ tuần tự cho gọn.
> GRN `CONFIRMED` cũng cập nhật trạng thái PO (`PARTIALLY_RECEIVED`/`COMPLETED`).

---

## WF-02: Lệnh in ly theo đơn hàng (UC-04)

```
MANAGER                    PRINTER                   Hệ thống
   |                          |                           |
   |-- Tạo Print Job -------->|                    Kiểm tồn CUP_BLANK
   |   (ly nền, design→SKU,   |                    Nếu đủ: GIỮ (reserved) blank
   |    qty)                   |                    Nếu thiếu: cảnh báo
   |                          |                    Job → PENDING
   |                          |                           |
   |                          |-- Quét SKU+shelf, in --->|
   |                          |                    Trừ thật CUP_BLANK
   |                          |                    (onHand−, reserved−)
   |                          |                    Job → IN_PROGRESS
   |                          |                           |
   |                          |-- Xác nhận in xong ------>|
   |                          |   Nhập CUP_PRINTED        |
   |                          |                    Cộng tồn CUP_PRINTED
   |                          |                    + reserve cho đơn
   |                          |                    (SKU per-design)
   |                          |                    Job → COMPLETED
```

> **Chuỗi hold (UC-04):** mở lệnh in = giữ blank **1 lần** (không reserve trùng với đơn); in xong **chuyển hold** sang `CUP_PRINTED.reserved` cho đúng đơn → UC-05 xuất trên printed. Nếu design đã có tồn CUP_PRINTED đủ → reserve thẳng ly in, **bỏ qua** lệnh in. Hủy lệnh khi `PENDING` → giải phóng reserved ly trắng.

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
   |   (kho nguồn → đích,     |                    Nếu đủ: reserve nguồn
   |    danh sách hàng)       |                    Transfer → CONFIRMED
   |                          |                    (event delta−)
   |                          |                           |
   |             [PICKER]     |-- Chuẩn bị tại kho nguồn->|
   |             [PICKER]     |-- Xác nhận xuất --------->|
   |                          |                    onHand−, reserved− (OUT)
   |                          |                    Transfer → IN_TRANSIT
   |                          |                           |
   |       [ Vận chuyển đến kho đích ]                    |
   |                          |                           |
   |           [RECEIVER]     |-- Xác nhận nhận tại đích->|
   |           [RECEIVER]     |   Chỉ định vị trí         |
   |                          |                    onHand+ kho đích (IN)
   |                          |                    Transfer → COMPLETED
   |                          |                    (event delta+)
   |-- Duyệt hoàn tất ------->|                           |
```

> **Tồn lúc transit:** available tổng giảm tạm từ `CONFIRMED` (reserve nguồn, event delta−) đến khi nhận đích (`TRANSFER_IN`, event delta+); net trọn vòng = 0. Bước xuất nguồn (`TRANSFER_OUT`) chỉ đổi onHand/vị trí, available không đổi.
