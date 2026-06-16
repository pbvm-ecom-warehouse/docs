# 01 — Kho & vị trí

> Bảng: `warehouses`, `zones`, `racks`, `shelves` · Schema gốc: [warehouse/data-model — Nhóm 1](../warehouse/data-model.md#nhóm-1-cấu-trúc-kho--vị-trí)

Mục tiêu của cụm này: **định danh từng vị trí vật lý trong kho** để hệ biết "hàng đang nằm đâu" và "cất/lấy ở đâu".

## Cây 4 cấp

```
Warehouse (kho)              vd: Kho Trung Tâm
  └── Zone (khu vực)         vd: Khu A
        └── Rack (kệ)        vd: Kệ A1
              └── Shelf (tầng/ô) vd: A1 tầng 2  ← đơn vị nhỏ nhất, có barcode
```

Mỗi cấp chỉ trỏ tới cấp cha (`zoneId`, `rackId`…) — quan hệ cha-con kinh điển.

## Từng bảng

### warehouses
| Field | Ý nghĩa |
|---|---|
| `isActive` | Kho ngừng hoạt động thì không nhận/xuất |

> **Hệ chỉ có 1 kho** (kho trung tâm) — bảng giữ đúng 1 dòng. Không có kho phụ / chuyển kho. Cấu trúc bảng giữ nguyên để dễ mở rộng đa kho về sau.

### zones / racks
Chỉ là cấp trung gian để tổ chức không gian. `code` (A, B / A1, A2) giúp người đọc hiểu, còn hệ định vị thật bằng **shelf**.

### shelves — quan trọng nhất
| Field | Ý nghĩa |
|---|---|
| `code` | **Giá trị barcode vị trí** — dán tem ở mỗi shelf. PICKER/RECEIVER **quét tem này** khi put-away/pick |
| `level` | Số tầng (1, 2, 3…) |
| `isStaging` | `true` = **shelf "khu nhận hàng"** — kho có 1, là nơi hàng nằm tạm sau khi nhận (GRN) trước khi xếp lên kệ thật |

## Vì sao tách `isStaging` riêng?

Khi hàng vừa về (GRN), nó **đã có trong kho** (tính vào `onHand`) nhưng **chưa được xếp đúng chỗ**. Hệ đặt nó vào shelf staging. Sau đó PutAway mới chuyển sang shelf thật. Nhờ vậy:

- `onHand` đúng ngay từ lúc nhận (không "thất lạc" hàng giữa nhận và xếp).
- Phân biệt rõ "hàng đã xếp" vs "hàng chờ xếp" mà không cần thêm trạng thái.

## Liên kết ra ngoài cụm

`shelves.id` được tham chiếu bởi rất nhiều bảng tồn & phiếu: `inventory_stocks.shelfId`, `stock_movements.shelfId`, `putaway_items.shelfId`, `goods_issue_items.shelfId`… — vì **mọi thao tác cất/lấy đều gắn với một vị trí cụ thể**.

---

← [00 — Khái niệm lõi](00-khai-niem-loi.md) · → [02 — Hàng hóa & tồn kho](02-hang-hoa-va-ton-kho.md)
