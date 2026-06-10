# Spec — Gợi ý vị trí put-away theo kích thước

> Trạng thái: 🔄 Đang phân tích
> Ngày: 2026-06-08
> Module: [warehouse/](../../warehouse/) — bổ sung cho **UC-03 Put-away**

## Vấn đề

Khi nhận hàng vào kho, mỗi loại mặt hàng có kích cỡ khác nhau. Bước **put-away (UC-03)** hiện tại để RECEIVER tự chọn shelf rồi quét barcode xác nhận — hệ **không gợi ý** nên đặt vào shelf nào, dễ đặt nhầm kệ quá nhỏ (hàng không lọt) hoặc phí chỗ. Cần tính năng **gợi ý vị trí**: dựa trên kích thước của kệ và của mặt hàng, cho biết mỗi shelf **còn chứa được bao nhiêu đơn vị** và đề xuất shelf phù hợp nhất.

## Mục tiêu & phạm vi

- **Fit + tối ưu lấp đầy (best-fit theo thể tích còn trống).** Lọc shelf chứa được, rồi chọn shelf tận dụng chỗ tốt nhất.
- Output cốt lõi: mỗi loại hàng có thể tích riêng → hệ tính shelf đó **còn chứa được ~N đơn vị** item đang put-away.
- **Advisory** — gợi ý tham khảo, RECEIVER vẫn quét barcode shelf để xác nhận (giữ nguyên luồng put-away hiện tại); được đặt khác gợi ý, hệ không cưỡng chế.

### Ngoài phạm vi (YAGNI)
- **Không** cân nặng / tải trọng — chỉ tính thể tích.
- **Không** 3D bin-packing thật (xoay-xếp tối ưu hình học).
- **Không** chiến lược slotting theo tốc độ bán (hàng bán chạy gần lối đi) — để sau.
- **Không** lưu trường occupied/used trên Shelf — tính động từ tồn thật.

## Quy ước

- Kích thước đo bằng **cm**, thể tích **cm³** (hiển thị có thể quy ra lít). Bộ 3 chiều **D×R×C** = sâu × rộng × cao.
- Mọi field kích thước **tùy chọn**. Thiếu kích thước → rơi về put-away nhập tay như hiện nay (không chặn nghiệp vụ).

## Thay đổi data-model

### Shelf — thêm field
| Field | Type | Mô tả |
|---|---|---|
| innerDepth | Number | Chiều sâu **lòng** tầng (cm) — tùy chọn |
| innerWidth | Number | Chiều rộng lòng tầng (cm) — tùy chọn |
| innerHeight | Number | Chiều cao khoảng tầng (cm) — tùy chọn |
| fillFactor | Number | Hệ số lấp đầy riêng shelf, override mặc định hệ thống — tùy chọn |

- `usableVolume = innerDepth × innerWidth × innerHeight` (dẫn xuất, không lưu).
- Shelf `isStaging = true` không cần kích thước (không bao giờ là đích gợi ý).
- `fillFactor` mặc định ở mức cấu hình hệ thống (vd `0.75`); shelf chỉ khai khi muốn ghi đè.

### WarehouseItem — thêm field
| Field | Type | Mô tả |
|---|---|---|
| depth | Number | Chiều sâu **1 đơn vị cơ sở** (cm) — tùy chọn |
| width | Number | Chiều rộng 1 đơn vị cơ sở (cm) — tùy chọn |
| height | Number | Chiều cao 1 đơn vị cơ sở (cm) — tùy chọn |

- `unitVolume = depth × width × height` (dẫn xuất). Khai lúc khai báo item, dùng lại cho mọi GRN.

## Thuật toán gợi ý

**Đầu vào:** item `I` (đã khai kích thước), số lượng cần put-away `Q`, kho `W`.

Với mỗi shelf `S` non-staging, đã khai kích thước, trong `W`:

1. **Ràng buộc 3 chiều (cho phép xoay 90°):** sắp giảm dần 3 chiều của `I` và của `S`; yêu cầu `I[i] ≤ S[i]` với mọi `i ∈ {0,1,2}`. Trượt → loại shelf (hàng quá to/dài không lọt tầng).
2. **Thể tích đã chiếm** `occupied = Σ (quantity × unitVolume)` của **mọi** InventoryStock trên `S` (mọi SKU & lô). Tính **động**, luôn khớp tồn thật — không lưu trường riêng.
3. **Còn trống** `free = usableVolume × fillFactor − occupied`.
4. **Sức chứa** `cap = floor(free / I.unitVolume)`. `cap ≥ 1` → shelf là ứng viên.

### Xếp hạng ứng viên (best-fit)
1. **Ưu tiên 1 — gom cùng SKU:** shelf đã chứa sẵn `I` và `cap ≥ Q` (gom 1 chỗ, dễ pick, ít phân mảnh).
2. **Ưu tiên 2 — best-fit:** trong các shelf đủ chứa `Q`, chọn shelf **`free` nhỏ nhất** (lấp khít, chừa kệ rộng cho hàng to về sau).
3. **Không shelf đơn nào đủ `Q`:** gợi ý **tổ hợp nhiều shelf** (put-away cho phép đặt nhiều vị trí; InventoryStock vốn đa-shelf). Hiển thị `shelf A: 30, shelf B: 20`.

### Output
Danh sách top gợi ý dạng `[mã shelf — còn chứa được N đơn vị]`. RECEIVER tới vị trí gợi ý → quét barcode SKU + quét barcode shelf để xác nhận (đúng chuẩn thao tác hiện tại).

## Edge cases
- **Item chưa khai kích thước** → không gợi ý; báo "chưa khai kích thước", RECEIVER nhập tay.
- **Shelf chưa khai kích thước** → bỏ khỏi danh sách gợi ý (không suy diễn vô hạn).
- **Hàng vượt mọi shelf** (trượt ràng buộc 3 chiều ở khắp nơi) → cảnh báo "hàng vượt mọi kệ", đề xuất kệ trống lớn nhất / xử lý thủ công.
- **`fillFactor` chỉ ước lượng** → số gợi ý là tham khảo; RECEIVER có thể đặt vượt, hệ không chặn.

## Bất biến cần giữ
- Sức chứa còn lại **luôn dẫn xuất** từ `InventoryStock` (lớp 2) — không thêm trường occupied phải đồng bộ.
- Gợi ý là **advisory**, không thay đổi luồng/transaction put-away đã có (chuyển hàng staging → shelf thật, `onHand` không đổi, không sync Ecommerce).
- Liên kết 2 app vẫn chỉ qua `sku`; tính năng này hoàn toàn nội bộ WMS.

## File sẽ cập nhật
- [warehouse/data-model.md](../../warehouse/data-model.md) — field Shelf + WarehouseItem + ghi chú dẫn xuất `usableVolume`/`unitVolume`.
- [warehouse/use-cases.md](../../warehouse/use-cases.md) — UC-03 thêm bước hệ gợi ý vị trí trước khi RECEIVER xác nhận.
- [warehouse/workflow.md](../../warehouse/workflow.md) — chèn bước "Gợi ý vị trí" vào WF put-away.
