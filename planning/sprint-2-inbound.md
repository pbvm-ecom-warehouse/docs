# Sprint 2 — Nhập kho (Week 2)

**Mục tiêu:** Hoàn chỉnh luồng nhập: tạo PO → nhận hàng (GRN cộng tồn) → put-away vào vị trí thật, kèm gợi ý vị trí. Dựng hạ tầng event để phát `stock.changed`.

**Định nghĩa Done sprint:** tạo PO → tạo GRN làm `onHand` tăng đúng (2 lớp + `StockMovement`) → put-away chuyển hàng staging→shelf, có API gợi ý vị trí trả danh sách shelf + sức chứa; event `stock.changed` phát ra queue.

## Issues

- [ ] [S2-01](issues/S2-01-supplier.md) — Supplier + SupplierItem (bảng giá, blacklist, guard giá) · `feat/M`
- [ ] [S2-02](issues/S2-02-purchase-order.md) — UC-01 Purchase Order · `feat/M` *(dep S2-01)*
- [ ] [S2-03](issues/S2-03-grn.md) — UC-02 GRN (lot/expiry, cộng tồn 2 lớp, barcode) · `feat/L` *(dep S1-04, S2-02)*
- [ ] [S2-04](issues/S2-04-putaway.md) — UC-03 Put-away (staging→shelf, khớp dòng GRN) · `feat/L` *(dep S2-03)*
- [ ] [S2-05](issues/S2-05-putaway-suggestion.md) — Thuật toán gợi ý vị trí put-away · `feat/M` *(dep S2-04)*
- [ ] [S2-06](issues/S2-06-event-infra.md) — Hạ tầng event BullMQ/Redis + phát `stock.changed` · `infra/M` *(dep S1-04)*

## Lưu ý điều phối

Chuỗi S2-02 → S2-03 → S2-04 → S2-05 tuần tự (cùng địa hạt nhập kho). S2-01 và S2-06 chạy song song độc lập. Nếu thiếu người, S2-05 (gợi ý) và S2-06 (event) có thể trượt sang đầu Sprint 3 mà không vỡ luồng nhập.
