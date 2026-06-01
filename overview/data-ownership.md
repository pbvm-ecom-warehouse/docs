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
goods_receipts                 orders
goods_issues                   customers
print_jobs                     carts
stock_transfers                payments
stock_counts
```

> **Không bao giờ đọc chéo collection trực tiếp giữa 2 app.**
> Liên kết duy nhất giữa 2 bên là `sku`.

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

Ecommerce không đọc `inventory_stocks` của WMS. WMS push event mỗi khi tồn kho thay đổi → Ecommerce tự cập nhật `availableQty` trong domain của mình.

### Luồng sync

```
WMS xuất kho 50 ly
  → push event: { sku: "LY-500ML", delta: -50 }
        ↓
Ecommerce worker nhận event
  → product_variants.availableQty -= 50
```

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
| `stock.changed` | WMS | Ecommerce | Nhập kho, xuất kho, chuyển kho, kiểm kho |
| `order.confirmed` | Ecommerce | WMS | Khách đặt hàng và thanh toán xong |
| `goods.issued` | WMS | Ecommerce | Xuất kho xong → cập nhật trạng thái đơn |
| `stock.low` | WMS | Notification | Tồn kho dưới ngưỡng `minQuantity` |
| `payment.success` | Ecommerce | Notification | Thanh toán thành công → email xác nhận |
| `goods.issued` | WMS | Notification | Hàng xuất kho → thông báo giao hàng |

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

Khi **chốt đơn**, phải giữ tồn **atomic** trên nguồn thật `wms_db.inventory_stocks` trong 1 transaction — vì cùng cluster nên làm được:

```
Đặt hàng → mở transaction:
  1. inventory_stocks: kiểm + trừ tồn (atomic, khóa document)
  2. tạo order
  → commit cùng lúc; nếu tồn không đủ → rollback + báo hết hàng
```

> Hai khách mua đồng thời ly cuối → chỉ 1 transaction commit được → **không bao giờ oversell**. Đây chính là lợi thế của monolith cùng cluster; nếu tách 2 MongoDB server riêng (microservices) thì mới phải dùng Saga.
