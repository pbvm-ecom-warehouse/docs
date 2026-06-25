# Capstone Project Registration

## 3.1. Capstone Project name:

**English:** StockFlow Commerce – Unified Warehouse & Online Store Platform for F&B Supplies with Custom Cup Printing

**Vietnamese:** Nền tảng Kho vận & Cửa hàng trực tuyến hợp nhất cho ngành F&B kèm In ly theo yêu cầu

### a. Context:

The food & beverage (F&B) retail sector — particularly bubble-tea and coffee shops — depends on a steady supply of materials (tea, milk, sugar, toppings, syrups), cups, lids, straws, and packaging. Suppliers of these goods usually run two disconnected systems: an internal warehouse spreadsheet for stock, and a separate online store for selling. This separation creates a clear market gap: stock displayed online drifts away from real on-hand quantities, leading to overselling, manual reconciliation, and lost orders. The problem is amplified by **custom-printed cups**, a make-to-order product that must be produced per customer design only after payment, yet must still be tracked against blank-cup inventory.

StockFlow Commerce closes this gap with a single platform that unifies **warehouse management (WMS)** and a **public e-commerce storefront** over one source of truth for inventory. The core invariant is anti-oversell: stock is reserved **atomically at checkout** against the warehouse, while the storefront shows a fast, event-synced copy of availability. The platform also industrializes the custom-cup workflow — turning each design into its own tracked product and orchestrating the blank-to-printed hold so a printed cup is always allocated to the correct order.

The two applications are linked **only by `sku`** and communicate **asynchronously via events** (BullMQ + Redis), keeping a clean module boundary while running on one MongoDB cluster, so consistency is preserved without distributed-transaction complexity.

### Functional requirement:

**Browse & Order**
- Customers browse the product catalog by category tree and search/filter by criteria: product type (materials, blank cups, printed cups, packaging), variant attributes (e.g., cup size S/M/L/XL), and availability.
- View detailed product and variant information: price, attributes, and a real-time–synced availability indicator (in-stock / out-of-stock).
- For custom-print cups, the customer must select a design — either by uploading a new design file or choosing from a saved design library — which is attached to the cart item.
- Add items to a cart that reads availability for warning only; the cart does **not** hold stock.

**Checkout & Anti-Oversell**
- At checkout the system performs an **atomic reserve** directly against the warehouse stock, holding inventory the moment the order is placed (for both COD and online payment).
- Reserve is decoupled from payment; stock is held immediately on order placement and released atomically on cancellation.
- Custom-print + COD is rejected: make-to-order items require **online prepayment**.
- Each order carries three independent status axes — `paymentStatus`, `orderStatus`, and `fulfillmentStatus` — to cleanly model the COD × online × make-to-order combinations; orders ship as whole units (no partial fulfillment).

**Payment**
- Online prepayment via an online payment gateway (VNPay sandbox), confirmed by an idempotent webhook that transitions the order to PAID / CONFIRMED.
- Cash on delivery (COD) for in-stock items: payment is captured as PAID upon successful delivery.
- Orders not paid before the payment deadline are auto-cancelled and their reserved stock is released.
- Refunds are issued for valid cancellations and approved returns.

**Inbound & Inventory Management**
- Managers create Purchase Orders (PO) to suppliers; Receivers record Goods Receipt Notes (GRN) against a PO and perform put-away to shelf locations.
- **Two-layer inventory:** a summary balance per SKU (`onHand`) equals the sum of per-shelf stock; `available = onHand − reserved − expired`. Every movement updates both layers within a single transaction, with an append-only stock-movement ledger for reconciliation.
- Single central warehouse with a Zone → Rack → Shelf location hierarchy; no multi-warehouse allocation or transfers.
- Stock counting (cycle/physical count) to reconcile recorded vs. actual quantities, and scrap handling for damaged or **expired** lots.

**Custom Cup Printing (Make-to-Order)**
- Each printed design is treated as its own SKU (per-design tracking).
- After a custom-print order is paid, the system opens a Print Job that holds (reserves) the required blank cups (`CUP_BLANK`).
- The Printer scans and confirms printing; on completion the hold is **transferred** from the blank cups to printed cups (`CUP_PRINTED`) allocated to the specific order.
- When all printed items for an order are ready, the order advances to ready-to-fulfill.

**Outbound Fulfillment & Shipping**
- Ready-to-fulfill orders generate a Goods Issue; the Picker scans and confirms the issue, decrementing on-hand and reserved against the previously held stock (availability is not deducted again).
- A shipment is created with carrier and tracking; the system drives the shipment lifecycle (Pending → Shipped → Delivered, or Returned on hard delivery failure).
- On successful delivery, COD orders are marked PAID and the order is closed.

**Cancellation & Returns (RMA)**
- Customers can cancel an order before goods issue; cancellation atomically releases the reserve and restores displayed availability, with refund for prepaid orders.
- Returns (RMA) after delivery are inspected: good items are restocked, damaged items are scrapped, and eligible refunds are processed. Custom-printed cups are non-returnable unless defective.

**Notifications**
- Real-time notifications for key lifecycle events (order confirmed, payment success, print completed, shipped, delivered) delivered via a shared notification service (email / SMS / push).

**Authentication & Admin Management**
- Registration/login and role-based access control across three actor groups: **Warehouse staff** (Admin, Manager, Receiver, Picker, Printer, Counter), **Shop staff** (Ecommerce Manager), and **Customers**.
- A user may hold multiple warehouse roles; the access guard grants access when the user's roles intersect the required roles (Admin bypasses all guards).
- Shop staff manage the catalog, set prices, and view/intervene in orders; warehouse staff operate the internal WMS app.

**Reporting**
- Dashboards and reports for inventory levels, stock movements, sales/revenue, and order fulfillment performance.

### Non-functional requirement:

**Performance & Scalability**
- Modular three-application architecture (WMS, E-commerce, Notification) built on NestJS, each scalable independently behind an Nginx reverse proxy.
- Target API response time < 2 seconds for common operations under normal demo workload.
- Asynchronous event processing (BullMQ + Redis) decouples cross-application work and smooths load spikes.

**Reliability & Availability**
- A single source of truth for inventory (warehouse stock balances) with a fast, event-synced read copy for the storefront prevents data divergence.
- Atomic reserve at checkout and transactional two-layer stock updates guarantee anti-oversell consistency without distributed transactions (single MongoDB cluster).
- State-machine–driven order lifecycle (three independent status axes) ensures consistent transitions and prevents loss of transaction data.

**Security**
- Role-Based Access Control (RBAC) for the three actor groups, with the internal WMS app IP-whitelisted.
- Stateless JWT access tokens signed with per-application RS256 keys (no shared secret); refresh tokens are hashed, stored, rotated on use, and revocable on logout / lockout / password reset.
- Encryption of sensitive data (personal and payment information) and integration with the payment gateway (VNPay sandbox) per its security standards; idempotent payment webhooks.

**Usability & Accessibility**
- User-friendly interface with Vietnamese support across two front-ends: a public storefront and an internal WMS console with role-based menus.
- Responsive design for desktop and mobile web.

**Maintainability & Extensibility**
- NestJS monorepo with shared libraries (auth, database, shared types, common utilities) and clear module boundaries, where the two applications are linked only by `sku` and communicate via events.
- Clean source code with API documentation, enabling modules to be added or split into independent services later with minimal coupling.
