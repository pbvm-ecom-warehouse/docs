# Data Ownership — Phân chia dữ liệu giữa các App

## Vấn đề

Cùng một sản phẩm nhưng WMS và Ecommerce nhìn theo 2 góc độ khác nhau:

| | WMS | Ecommerce |
|---|---|---|
| Quan tâm đến | SKU, số lượng, vị trí kho (Zone/Rack/Shelf), đơn vị tính | Tên hiển thị, ảnh, mô tả, giá bán, danh mục, SEO |
| Không quan tâm | Giá, ảnh, SEO | Zone, Rack, Shelf, batch number |
| Ví dụ | "Ly nhựa 500ml — B2/Tầng 3 — 200 cái" | "Ly nhựa in logo — 5.000đ/cái — Ảnh đẹp" |

---

## Nguyên tắc: 2 logical DB, mỗi app sở hữu collection riêng

> 1 MongoDB cluster tách thành 2 database logic — `wms_db` (collection của WMS) và `ecom_db` (collection của Ecommerce). Cùng cluster nên transaction atomic xuyên 2 DB **vẫn làm được** khi cần (vd: giữ tồn lúc đặt hàng), không phải dùng Saga.

```
WMS sở hữu:                    Ecommerce sở hữu:
────────────────────           ──────────────────────
warehouse_items                products
inventory_stocks               product_variants
goods_receipts                 categories
goods_issues                   designs
print_jobs                     orders
stock_transfers                customers
stock_counts                   carts
suppliers                      payments
supplier_items
```

> **Không bao giờ đọc chéo collection trực tiếp giữa 2 app.**
> Liên kết duy nhất giữa 2 bên là `sku`.

> Bên Ecommerce, `categories`/`products`/`product_variants`/`designs` do **module Catalog** sở hữu; `orders`/`carts`/`payments` do **module Order**; `customers` (tài khoản khách) do **module Auth** sở hữu — Order/Catalog chỉ trỏ `customerId`, **không định nghĩa schema Customer** (xem [gap-analysis](./gap-analysis.md#2-auth--user--hạng-2)). Xem [Catalog data-model](../catalog/data-model.md).

---

## Sản phẩm được tạo thế nào?

Không phải mọi item trong WMS đều bán trên Ecommerce (ví dụ: nguyên liệu thô không bán cho khách). Vì vậy mỗi app tự quản lý entity sản phẩm của mình.

```
WMS — warehouse_items          Ecommerce — products
─────────────────────          ────────────────────────
sku: "LY-500ML"                sku: "LY-500ML"   ← cùng SKU để sync tồn kho
name: "Ly nhựa 500ml"          name: "Ly nhựa in logo cao cấp"
unit: "cái"                    description: "Ly cao cấp, in được logo..."
type: CUP_BLANK                images: ["img1.jpg", "img2.jpg"]
                               price: 5000
                               availableQty: 200   ← WMS sync sang
```

---

## Sync tồn kho qua Event

Ecommerce không đọc tồn của WMS. WMS push event mỗi khi **`available` đổi** (`available = StockBalance.onHand − reserved − expired`) → Ecommerce tự cập nhật `availableQty` trong domain của mình. *(Lô hết hạn rơi vào `expired` → tự loại khỏi hàng bán.)*

> **`availableQty` là tổng gộp mọi kho** của một SKU (`Σ available` trên các kho). Ecommerce không phân biệt kho khi bán; việc chọn kho xuất xảy ra lúc chốt đơn (xem [Chống oversell](#chống-oversell-khi-xác-nhận-đơn)). Chuyển kho bắn **2 event lệch dấu** (delta− khi reserve kho nguồn lúc `CONFIRMED`, delta+ khi nhận kho đích `TRANSFER_IN`) → `available` **giảm tạm trong lúc transit**, net trọn vòng = 0.

### Luồng sync

`availableQty` (bản copy bên Ecom) có **2 đường cập nhật**, không trùng đếm:

**Đường 1 — biến động phía WMS** (GRN, kiểm kho, chuyển kho, in-vào-kho, hết hạn): WMS phát `stock.changed`/`stock.expired`, Ecom worker cộng dồn.

```
WMS nhập kho 200 ly (onHand += 200 → available += 200)
  → push event: { sku: "LY-500ML", delta: +200 }
        ↓
Ecommerce worker nhận event
  → product_variants.availableQty += 200
```

**Đường 2 — reserve/release lúc checkout/hủy** (do Ecom khởi xướng): Ecom tự trừ/cộng `availableQty` **ngay trong transaction** checkout/hủy, **không** qua event (xem [Chống oversell](#chống-oversell-khi-xác-nhận-đơn)).

> Lúc PICKER xuất kho thật, `onHand -= 50` và `reserved -= 50` → `available` **không đổi** → không bắn event (đã trừ từ lúc chốt đơn, tránh trừ 2 lần).

### Code mẫu

```typescript
// apps/wms — sau khi xác nhận xuất kho
await this.stockQueue.add('stock.changed', {
  sku: variant.sku,
  delta: -quantity,   // âm = giảm tồn, dương = tăng tồn
});
```

```typescript
// apps/ecommerce — worker lắng nghe
@Processor('stock-queue')
export class StockProcessor {
  @Process('stock.changed')
  async handleStockChanged(job: Job<{ sku: string; delta: number }>) {
    const { sku, delta } = job.data;
    await this.productVariantService.updateAvailableQty(sku, delta);
  }
}
```

---

## Các event đồng bộ giữa WMS và Ecommerce

| Event | Từ | Đến | Khi nào |
|---|---|---|---|
| `stock.changed` | WMS | Ecommerce | **Khi `available` (tổng gộp mọi kho) đổi do biến động phía WMS**: nhập kho (GRN), kiểm kho điều chỉnh, chuyển kho (reserve nguồn lúc `CONFIRMED` −/nhận đích +), in ly (blank↓ khi tạo lệnh; printed↑ **chỉ khi in vào kho, không gắn đơn**), hoàn hàng. *(KHÔNG bắn khi: put-away, pick-xuất, **scrap**; **cũng KHÔNG bắn cho reserve/release lúc checkout/hủy đơn** — Ecom tự trừ/cộng `availableQty` ngay trong transaction, xem [Chống oversell](#chống-oversell-khi-xác-nhận-đơn))* |
| `order.placed` | Ecommerce | WMS | **Khách chốt đơn (cả COD/online)** → **thông báo thuần** để WMS ghi nhận đơn. **KHÔNG reserve ở đây** — tồn đã giữ atomic ngay trong transaction checkout (Ecom ghi thẳng `wms_db.stock_balances`, xem [Chống oversell](#chống-oversell-khi-xác-nhận-đơn)). Trigger xuất kho là `order.ready_to_fulfill` |
| `print.requested` | Ecommerce | WMS | `payment.success` & đơn có ly-in → WMS mở PrintJob (UC-04) cho từng ly-in (make-to-order chỉ chạy sau khi đã trả) |
| `order.cancelled` | Ecommerce | WMS | Hủy đơn trước khi xuất → **thông báo thuần**; release reserve (`reserved −= qty`) + `availableQty += qty` đã do Ecom làm atomic trong transaction hủy. WMS ghi nhận để dừng downstream |
| `order.returned` | Ecommerce | WMS | Khách trả hàng → WMS mở phiếu hoàn (UC-09), nhập lại hàng tốt |
| `print.completed` | WMS | Ecommerce | PrintJob của đơn in xong → Ecom set `OrderItem.printJobId`; đã in xong **mọi** ly-in của đơn → lật `fulfillmentStatus: AWAITING_PRINT → READY_TO_PICK` |
| `order.ready_to_fulfill` | Ecommerce | WMS | Đơn vào `READY_TO_PICK` (COD ngay sau checkout / online-không-in khi `payment.success` / đơn ly-in sau khi in xong) → WMS sinh `GoodsIssue` (UC-05) xuất từ `fulfillWarehouseId` |
| `goods.issued` | WMS | Ecommerce | Xuất kho xong → cập nhật trạng thái đơn *(không trừ available lần nữa — đã trừ lúc chốt đơn)* |
| `stock.low` | WMS | Notification | `available < minQuantity` |
| `stock.near_expiry` | WMS | Notification | Lô còn ≤ `nearExpiryDays` ngày tới hạn (job định kỳ) |
| `stock.expired` | WMS | Ecommerce | Lô tới hạn → `expired +=`, `available` giảm → cập nhật `availableQty` |
| `payment.success` | Ecommerce | Notification | Thanh toán thành công → email xác nhận |
| `goods.issued` | WMS | Notification | Hàng xuất kho → thông báo giao hàng |

> **Catalog là consumer tồn:** `stock.changed` và `stock.expired` được module **Catalog** (Ecommerce) tiêu thụ → cập nhật `ProductVariant.availableQty` (match theo `sku`). Xem [Catalog data-model](../catalog/data-model.md).

---

## Kiểm tra tồn kho khi đặt hàng (Sync)

Trước khi xác nhận đơn, Ecommerce cần biết còn đủ hàng không. Thay vì gọi WMS API, Ecommerce đọc `availableQty` từ chính collection của mình (đã được WMS sync về):

```typescript
// apps/ecommerce
async validateStock(items: OrderItem[]) {
  for (const item of items) {
    const variant = await this.prisma.productVariant.findUnique({
      where: { sku: item.sku }
    });
    if (variant.availableQty < item.quantity) {
      throw new BadRequestException(`${item.sku} không đủ hàng`);
    }
  }
}
```

> Không cần HTTP call sang WMS — nhanh, không phụ thuộc WMS uptime.

---

## Chống oversell khi xác nhận đơn

`validateStock` ở trên chỉ là **kiểm tra sơ bộ** dựa trên bản copy `availableQty` (có thể trễ vì sync bất đồng bộ). Nếu 2 khách mua cùng lúc món cuối cùng, cả 2 đều đọc `availableQty = 1` → cả 2 đơn lọt → oversell.

Khi **chốt đơn**, phải giữ tồn **atomic** trên nguồn thật `wms_db.stock_balances` trong 1 transaction — vì cùng cluster nên làm được:

Đặt hàng → chọn kho có available ≥ qty (ưu tiên CENTRAL) → mở transaction (xuyên 2 logical DB cùng cluster):
  1. wms_db.stock_balances: kiểm `onHand − reserved ≥ qty` rồi `reserved += qty` (atomic, khóa document)
  2. ecom_db.product_variants: `availableQty −= qty` (Ecom tự trừ bản copy của mình — không qua event)
  3. ecom_db.orders: tạo Order + OrderItem (snapshot)
  → commit cùng lúc; nếu không đủ → rollback + báo hết hàng

> Giữ tồn ở **lớp tổng** (`stock_balances`), chưa cần biết shelf — PICKER chọn vị trí lấy sau ở khâu xuất kho.

> Hai khách mua đồng thời ly cuối → chỉ 1 transaction commit được → **không bao giờ oversell**. Đây chính là lợi thế của monolith cùng cluster; nếu tách 2 MongoDB server riêng (microservices) thì mới phải dùng Saga.

> **Reserve tách khỏi thanh toán:** tồn được giữ ngay khi đặt (atomic trong transaction checkout — `order.placed` chỉ là thông báo thuần), áp dụng cho cả COD và online. Thanh toán (`payment.success`) chỉ dùng để **xác nhận đơn online** và **mở lệnh in** cho đơn ly-in (`print.requested`). Đơn online quá hạn chưa trả → tự `order.cancelled` (release reserve).

### Phân bổ kho khi chốt đơn (chưa hỗ trợ split đa kho)

- Đơn được giữ tồn ở **một kho duy nhất** có `available ≥ qty` (ưu tiên `CENTRAL`). Kho được chọn phải **lưu lại trên đơn** (vd `order.fulfillWarehouseId`) để GoodsIssue (UC-05) xuất đúng kho đã giữ.
- **Chưa hỗ trợ split đa kho:** nếu không kho đơn lẻ nào đủ hàng — dù **tổng** mọi kho đủ — đơn bị **từ chối** (báo hết hàng). Khi cần đáp ứng đơn vượt tồn 1 kho, dùng [Chuyển kho (UC-07)](../warehouse/use-cases.md#uc-07-chuyển-kho-stock-transfer) gom hàng về một kho trước.
