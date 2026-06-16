# Planning — Backlog 4 tuần hiện thực hóa app WMS

> Nguồn thiết kế: [spec 2026-06-15](../superpowers/specs/2026-06-15-wms-4-week-sprint-plan-design.md).
> Đích cuối tuần 4: **app WMS nội bộ chạy vững** — `PO → GRN → Put-away (+ gợi ý vị trí) → Xuất kho → Kiểm kê → In ly`. Ecom ngoài phạm vi (chỉ chừa event `stock.changed`).

## Sprint (1 tuần/sprint · đội 2-3 dev · code từ đầu)

| Sprint | Chủ đề | File | Issues |
|---|---|---|---|
| 1 | Nền móng & Auth | [sprint-1-foundation.md](sprint-1-foundation.md) | S1-01 → S1-05 |
| 2 | Nhập kho | [sprint-2-inbound.md](sprint-2-inbound.md) | S2-01 → S2-06 |
| 3 | Xuất kho & nội bộ | [sprint-3-outbound-internal.md](sprint-3-outbound-internal.md) | S3-01 → S3-03 |
| 4 | Hoàn thiện & Báo cáo | [sprint-4-hardening-reports.md](sprint-4-hardening-reports.md) | S4-01 → S4-06 |

## Quy ước nhãn (label)

| Nhóm | Giá trị |
|---|---|
| `type` | `infra` · `feat` · `docs` · `test` |
| `module` | `warehouse` · `auth` · `supplier` · `report` · `notification` |
| `sprint` | `sprint:1` … `sprint:4` |
| `size` | `size:S` (≤0.5d) · `size:M` (~1-2d) · `size:L` (~3d+) |

Mỗi issue ghi `depends-on` (mã issue tiền đề) trong phần đầu file.

## Bất biến phải giữ khi code

- **Tồn 2 lớp:** `StockBalance.onHand` = Σ `InventoryStock.quantity`; `available = onHand − reserved − expired`. Cập nhật **cả 2 lớp trong 1 transaction**.
- **`StockMovement`** = sổ cái append-only mọi biến động tồn.
- **Barcode** ở mọi bước chạm hàng vật lý.
- Định danh collection/enum/event khớp [data-ownership.md](../overview/data-ownership.md) + [system-context.md](../overview/system-context.md).

## Đẩy lên GitHub Issues

`gh` chưa cài trong môi trường. Sau khi cài + `gh auth login`:

```bash
bash planning/scripts/create-issues.sh        # tạo label + issue từ planning/issues/*.md
bash planning/scripts/create-issues.sh --dry-run   # xem trước, không tạo gì
```

Script đọc frontmatter (`title`, `labels`) mỗi file issue, phần còn lại làm body.
