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
```

> **Định danh bằng barcode:** ở các bước chạm hàng vật lý — nhận hàng (WF-01 GRN), put-away, xuất kho (WF-03) — thao tác chuẩn là **quét barcode SKU + quét barcode vị trí (shelf)** rồi mới xác nhận. Hệ tự khớp dòng chứng từ; quét sai item/vị trí hoặc lệch qty → cảnh báo.

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

> **Gợi ý vị trí put-away (advisory, theo kích thước):** với item `I` đã khai `unitVolume`, số lượng `Q`, trong kho `W` — hệ duyệt mọi shelf non-staging đã khai kích thước:
> 1. **Ràng buộc 3 chiều (cho xoay 90°):** sắp giảm dần 3 chiều của `I` và shelf; yêu cầu `I[i] ≤ shelf[i]` mọi chiều — trượt thì loại (hàng quá to/dài không lọt tầng).
> 2. **Đã chiếm** = `Σ (quantity × unitVolume)` mọi `InventoryStock` trên shelf (mọi SKU & lô) — tính **động** từ tồn thật, không lưu trường riêng.
> 3. **Còn trống** = `usableVolume × fillFactor − đã chiếm`; **sức chứa** = `floor(còn trống ÷ I.unitVolume)`.
> 4. **Xếp hạng:** ưu tiên shelf đã chứa cùng SKU (đủ `Q`) → rồi **best-fit** (còn trống nhỏ nhất mà vẫn đủ `Q`). Không shelf đơn nào đủ `Q` → gợi ý tổ hợp nhiều shelf (`A: 30, B: 20`).
> 5. **Output:** `[mã shelf — còn chứa được N đơn vị]`; RECEIVER vẫn quét SKU + shelf để xác nhận, được đặt khác gợi ý. Hàng vượt mọi shelf → cảnh báo, xử lý thủ công.
>
> Định nghĩa field & dẫn xuất `usableVolume`/`unitVolume`: [data-model.md → Cấu trúc kho](data-model.md#nhóm-1-cấu-trúc-kho--vị-trí).

---

## WF-02: Lệnh in ly theo đơn hàng (UC-04)

```
MANAGER                    PRINTER                   Hệ thống
   |                          |                           |
   |-- Tạo Print Job -------->|                    Kiểm tồn CUP_BLANK
   |   (ly nền, design→SKU,   |                    Nếu đủ: GIỮ (reserved) blank
   |    qty)                  |                    Nếu thiếu: cảnh báo
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

