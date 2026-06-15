# Sprint 3 — Xuất kho & nội bộ (Week 3)

**Mục tiêu:** Hoàn chỉnh các luồng làm giảm/di chuyển tồn: soạn & xuất hàng, in ly make-to-order, kiểm kê điều chỉnh, chuyển kho.

**Định nghĩa Done sprint:** xuất hàng trừ tồn đúng 2 lớp + phát `goods.issued`; PrintJob chuyển `CUP_BLANK`→`CUP_PRINTED`; kiểm kê sinh adjustment đúng chênh lệch; chuyển kho làm tồn kho nguồn giảm và kho đích tăng nhất quán.

## Issues

- [ ] [S3-01](issues/S3-01-goods-issue.md) — UC-05 Soạn & xuất hàng (pick, trừ tồn, `goods.issued`) · `feat/L` *(dep S1-04, S2-06)*
- [ ] [S3-02](issues/S3-02-cup-printing.md) — UC-04 In ly make-to-order (hold CUP_BLANK→CUP_PRINTED) · `feat/L` *(dep S1-04)*
- [ ] [S3-03](issues/S3-03-stock-count.md) — UC-06 Kiểm kê & điều chỉnh tồn · `feat/M` *(dep S1-04)*
- [ ] [S3-04](issues/S3-04-stock-transfer.md) — UC-07 Chuyển kho · `feat/L` *(dep S3-01)*

## Lưu ý điều phối

4 issue khá độc lập (cùng dùng helper tồn 2 lớp từ S1-04) → chia song song tốt. S3-04 nên làm sau S3-01 vì tái dùng logic xuất kho phía kho nguồn.
