-- (Staxio – hackathon edition, SQLite 3.33+)
--
-- SIMPLIFICATIONS:
--  * Single currency (INR). Money = INTEGER paise (₹560.00 = 56000). Show with amount/100.
--  * A "quotation" is simply a subscription in status 'quotation' (no separate quotation tables).
--  * One tax per line (tax_rate_id), percentage, exclusive. Tax is snapshotted on invoice lines.
--  * A payment is made directly against ONE invoice (no allocation table).
--  * "Overdue" and "partially paid" are DERIVED in views, never stored.
--  * Totals are computed by the app when creating an invoice (sum of lines). No header totals on subscriptions.
--  * Numbers (SUB-00001, INV-00001, PAY-00001) = prefix + zero-padded row id, set by the app right after insert.
--  * Password policy (>8 chars, upper, lower, special) + email lower-casing + role checks live in Flask.
--  * Dates 'YYYY-MM-DD', timestamps UTC 'YYYY-MM-DD HH:MM:SS'.


PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- =====================================================================
-- 1. AUTH + ROLES
-- =====================================================================
CREATE TABLE users (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    full_name          TEXT NOT NULL,
    email              TEXT NOT NULL UNIQUE COLLATE NOCASE
                       CHECK (email COLLATE BINARY = lower(email) AND email LIKE '_%@_%._%'),
    password_hash      TEXT NOT NULL CHECK (length(password_hash) >= 20),
    role               TEXT NOT NULL CHECK (role IN ('admin','staff','customer','finance_lead')),
    is_active          INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    reset_token_hash   TEXT,                 -- sha256 of emailed token
    reset_expires_at   TEXT,
    created_by         INTEGER REFERENCES users(id) ON DELETE SET NULL,  -- admin who added staff
    created_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_users_reset ON users(reset_token_hash) WHERE reset_token_hash IS NOT NULL;

CREATE TABLE customers (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id             INTEGER UNIQUE REFERENCES users(id) ON DELETE SET NULL,  -- portal login
    name                TEXT NOT NULL,
    company_name        TEXT,
    email               TEXT NOT NULL,
    phone               TEXT,
    tax_number          TEXT,                -- GSTIN
    address             TEXT,
    payment_terms_days  INTEGER NOT NULL DEFAULT 30 CHECK (payment_terms_days >= 0),
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_customers_name ON customers(name);

-- =====================================================================
-- 2. TAXES, PRODUCTS, VARIANTS
-- =====================================================================
CREATE TABLE tax_rates (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT NOT NULL,                       -- 'GST 18%'
    rate       REAL NOT NULL CHECK (rate >= 0 AND rate <= 100),
    is_active  INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1))
);

CREATE TABLE products (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    name          TEXT NOT NULL,
    product_type  TEXT NOT NULL CHECK (product_type IN ('software','service','add-on','other')),
    sales_price   INTEGER NOT NULL DEFAULT 0 CHECK (sales_price >= 0),
    cost_price    INTEGER NOT NULL DEFAULT 0 CHECK (cost_price >= 0),
    tax_rate_id   INTEGER REFERENCES tax_rates(id) ON DELETE SET NULL,   -- default tax for lines
    notes         TEXT,
    is_active     INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);

CREATE TABLE product_variants (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    product_id        INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    attribute_name    TEXT NOT NULL,                 -- 'brand'
    attribute_value   TEXT NOT NULL,                 -- 'Odoo'
    price_adjustment  INTEGER NOT NULL DEFAULT 0,    -- paise, +56000 = ₹560 extra
    UNIQUE (product_id, attribute_name, attribute_value)
);

-- =====================================================================
-- 3. PLANS + QUOTATION TEMPLATES
-- =====================================================================
CREATE TABLE plans (
    id                        INTEGER PRIMARY KEY AUTOINCREMENT,
    name                      TEXT NOT NULL,
    billing_frequency         TEXT NOT NULL CHECK (billing_frequency IN ('daily','weekly','monthly','yearly')),
    billing_interval          INTEGER NOT NULL DEFAULT 1 CHECK (billing_interval > 0),
    price                     INTEGER NOT NULL DEFAULT 0 CHECK (price >= 0),
    minimum_quantity          INTEGER NOT NULL DEFAULT 1 CHECK (minimum_quantity > 0),   -- app checks line qty
    available_from            TEXT,
    available_until           TEXT,
    auto_close_on_expiry      INTEGER NOT NULL DEFAULT 0 CHECK (auto_close_on_expiry IN (0,1)),
    allow_early_cancellation  INTEGER NOT NULL DEFAULT 1 CHECK (allow_early_cancellation IN (0,1)),
    allow_pause               INTEGER NOT NULL DEFAULT 1 CHECK (allow_pause IN (0,1)),
    allow_renewal             INTEGER NOT NULL DEFAULT 1 CHECK (allow_renewal IN (0,1)),
    is_active                 INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    CHECK (available_until IS NULL OR available_from IS NULL OR available_until >= available_from)
);

-- product lines that come with a plan (copied onto new subscriptions)
CREATE TABLE plan_lines (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    plan_id     INTEGER NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
    product_id  INTEGER NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    variant_id  INTEGER REFERENCES product_variants(id) ON DELETE SET NULL,
    quantity    INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit_price  INTEGER NOT NULL CHECK (unit_price >= 0)
);
CREATE INDEX idx_plan_lines_plan ON plan_lines(plan_id);

CREATE TABLE quotation_templates (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    name           TEXT NOT NULL,
    plan_id        INTEGER NOT NULL REFERENCES plans(id) ON DELETE RESTRICT,
    validity_days  INTEGER NOT NULL DEFAULT 30 CHECK (validity_days > 0),
    is_active      INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1))
);

CREATE TABLE quotation_template_lines (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    template_id  INTEGER NOT NULL REFERENCES quotation_templates(id) ON DELETE CASCADE,
    product_id   INTEGER NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    variant_id   INTEGER REFERENCES product_variants(id) ON DELETE SET NULL,
    quantity     INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit_price   INTEGER NOT NULL CHECK (unit_price >= 0)
);
CREATE INDEX idx_qtl_template ON quotation_template_lines(template_id);

-- =====================================================================
-- 4. SUBSCRIPTIONS  (Draft -> Quotation -> Confirmed -> Active -> Closed)
-- =====================================================================
CREATE TABLE subscriptions (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_number  TEXT UNIQUE,                    -- 'SUB-00001', set by app after insert
    customer_id          INTEGER NOT NULL REFERENCES customers(id) ON DELETE RESTRICT,
    plan_id              INTEGER NOT NULL REFERENCES plans(id) ON DELETE RESTRICT,
    template_id          INTEGER REFERENCES quotation_templates(id) ON DELETE SET NULL,
    status               TEXT NOT NULL DEFAULT 'draft'
                         CHECK (status IN ('draft','quotation','confirmed','active','paused','cancelled','expired','closed')),
    quote_valid_until    TEXT,                           -- quotation_date + template.validity_days
    start_date           TEXT NOT NULL,
    expiry_date          TEXT,
    next_billing_date    TEXT,                           -- set when it becomes active
    payment_terms_days   INTEGER NOT NULL DEFAULT 30 CHECK (payment_terms_days >= 0),
    renewed_from_id      INTEGER REFERENCES subscriptions(id) ON DELETE SET NULL,
    cancellation_reason  TEXT,
    created_by           INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    CHECK (expiry_date IS NULL OR expiry_date >= start_date)
);
CREATE INDEX idx_subs_customer ON subscriptions(customer_id, status);
CREATE INDEX idx_subs_status   ON subscriptions(status);
CREATE INDEX idx_subs_billing  ON subscriptions(next_billing_date) WHERE status = 'active';

CREATE TABLE subscription_lines (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id  INTEGER NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    product_id       INTEGER REFERENCES products(id) ON DELETE SET NULL,
    variant_id       INTEGER REFERENCES product_variants(id) ON DELETE SET NULL,
    description      TEXT NOT NULL,
    quantity         INTEGER NOT NULL CHECK (quantity > 0),
    unit_price       INTEGER NOT NULL CHECK (unit_price >= 0),
    tax_rate_id      INTEGER REFERENCES tax_rates(id) ON DELETE SET NULL,
    is_active        INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1))   -- add-ons switched on/off
);
CREATE INDEX idx_sub_lines_sub ON subscription_lines(subscription_id);

-- status log: powers "anyone can see where it stands" (filled by trigger below)
CREATE TABLE subscription_events (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id  INTEGER NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    from_status      TEXT,
    to_status        TEXT NOT NULL,
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_sub_events_sub ON subscription_events(subscription_id);

-- =====================================================================
-- 5. DISCOUNTS (admin creates; auto-applied on next invoice)
-- =====================================================================
CREATE TABLE discounts (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    name              TEXT NOT NULL,
    code              TEXT UNIQUE,
    discount_type     TEXT NOT NULL CHECK (discount_type IN ('fixed','percentage')),
    discount_value    REAL NOT NULL CHECK (discount_value >= 0),     -- paise if fixed, % if percentage
    minimum_purchase  INTEGER NOT NULL DEFAULT 0 CHECK (minimum_purchase >= 0),
    minimum_quantity  INTEGER NOT NULL DEFAULT 0 CHECK (minimum_quantity >= 0),
    product_id        INTEGER REFERENCES products(id) ON DELETE CASCADE,  -- NULL = whole subscription
    valid_from        TEXT,
    valid_until       TEXT,
    usage_limit       INTEGER CHECK (usage_limit IS NULL OR usage_limit > 0),
    usage_count       INTEGER NOT NULL DEFAULT 0 CHECK (usage_count >= 0),
    is_active         INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_by        INTEGER REFERENCES users(id) ON DELETE SET NULL,
    CHECK (discount_type <> 'percentage' OR discount_value <= 100),
    CHECK (valid_until IS NULL OR valid_from IS NULL OR valid_until >= valid_from),
    CHECK (usage_limit IS NULL OR usage_count <= usage_limit)
);

-- which discounts are attached to which subscription
CREATE TABLE subscription_discounts (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id  INTEGER NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    discount_id      INTEGER NOT NULL REFERENCES discounts(id) ON DELETE RESTRICT,
    UNIQUE (subscription_id, discount_id)
);

-- =====================================================================
-- 6. INVOICES (generated from subscriptions) + PAYMENTS
-- =====================================================================
CREATE TABLE invoices (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    invoice_number    TEXT UNIQUE,                       -- 'INV-00001', set by app after insert
    customer_id       INTEGER NOT NULL REFERENCES customers(id) ON DELETE RESTRICT,
    subscription_id   INTEGER REFERENCES subscriptions(id) ON DELETE RESTRICT,
    status            TEXT NOT NULL DEFAULT 'draft'
                      CHECK (status IN ('draft','confirmed','paid','cancelled')),
    invoice_date      TEXT NOT NULL,
    due_date          TEXT NOT NULL,
    period_start      TEXT,
    period_end        TEXT,
    customer_name     TEXT NOT NULL,                     -- snapshots
    customer_address  TEXT,
    customer_tax_number TEXT,
    subtotal          INTEGER NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    discount_total    INTEGER NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
    tax_total         INTEGER NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
    total_amount      INTEGER NOT NULL DEFAULT 0 CHECK (total_amount >= 0),   -- subtotal - discount + tax
    amount_paid       INTEGER NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
    sent_at           TEXT,
    paid_at           TEXT,
    cancelled_at      TEXT,
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    CHECK (due_date >= invoice_date),
    CHECK (amount_paid <= total_amount)
);
CREATE INDEX idx_invoices_customer ON invoices(customer_id, status);
CREATE INDEX idx_invoices_status_due ON invoices(status, due_date);
CREATE INDEX idx_invoices_date ON invoices(invoice_date);
-- "nothing billed twice": one live invoice per subscription per billing period
CREATE UNIQUE INDEX uq_invoice_period ON invoices(subscription_id, period_start, period_end)
    WHERE subscription_id IS NOT NULL AND period_start IS NOT NULL AND status <> 'cancelled';

CREATE TABLE invoice_lines (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    invoice_id       INTEGER NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    product_id       INTEGER REFERENCES products(id) ON DELETE SET NULL,
    description      TEXT NOT NULL,
    quantity         INTEGER NOT NULL CHECK (quantity > 0),
    unit_price       INTEGER NOT NULL CHECK (unit_price >= 0),
    discount_amount  INTEGER NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    tax_name         TEXT,                               -- snapshot
    tax_rate         REAL NOT NULL DEFAULT 0,            -- snapshot %
    tax_amount       INTEGER NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    line_total       INTEGER NOT NULL CHECK (line_total >= 0),   -- qty*price - discount + tax
    CHECK (discount_amount <= quantity * unit_price)
);
CREATE INDEX idx_inv_lines_invoice ON invoice_lines(invoice_id);

-- discounts that were applied on an invoice (trigger bumps usage_count)
CREATE TABLE invoice_discounts (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    invoice_id   INTEGER NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    discount_id  INTEGER NOT NULL REFERENCES discounts(id) ON DELETE RESTRICT,
    amount       INTEGER NOT NULL CHECK (amount >= 0),
    UNIQUE (invoice_id, discount_id)
);

CREATE TABLE payments (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    payment_number     TEXT UNIQUE,                      -- 'PAY-00001', set by app after insert
    invoice_id         INTEGER NOT NULL REFERENCES invoices(id) ON DELETE RESTRICT,
    customer_id        INTEGER NOT NULL REFERENCES customers(id) ON DELETE RESTRICT,
    method             TEXT NOT NULL CHECK (method IN ('cash','bank_transfer','card','upi','cheque','other')),
    amount             INTEGER NOT NULL CHECK (amount > 0),
    payment_date       TEXT NOT NULL,
    note               TEXT,
    recorded_by        INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at         TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_payments_invoice ON payments(invoice_id);
CREATE INDEX idx_payments_customer ON payments(customer_id, payment_date);
CREATE INDEX idx_payments_date ON payments(payment_date);

-- =====================================================================
-- 7. TRIGGERS (guard rails so Flask stays small)
-- =====================================================================
-- 7a. Subscription lifecycle + plan rules
CREATE TRIGGER trg_sub_status_guard BEFORE UPDATE OF status ON subscriptions
WHEN NEW.status <> OLD.status
BEGIN
    SELECT RAISE(ABORT, 'Invalid subscription status change')
    WHERE (OLD.status || '>' || NEW.status) NOT IN (
        'draft>quotation','draft>confirmed','draft>cancelled',
        'quotation>draft','quotation>confirmed','quotation>cancelled',
        'confirmed>active','confirmed>cancelled',
        'active>paused','active>cancelled','active>expired','active>closed',
        'paused>active','paused>cancelled','paused>closed',
        'expired>closed','cancelled>closed');
    SELECT RAISE(ABORT, 'This plan does not allow pausing')
    WHERE NEW.status = 'paused'
      AND (SELECT allow_pause FROM plans WHERE id = NEW.plan_id) = 0;
    SELECT RAISE(ABORT, 'This plan does not allow early cancellation or closing')
    WHERE NEW.status IN ('cancelled','closed') AND OLD.status IN ('active','paused')
      AND NEW.expiry_date IS NOT NULL AND date('now') < NEW.expiry_date
      AND (SELECT allow_early_cancellation FROM plans WHERE id = NEW.plan_id) = 0;
END;

CREATE TRIGGER trg_sub_status_log AFTER UPDATE OF status ON subscriptions
WHEN NEW.status <> OLD.status
BEGIN
    INSERT INTO subscription_events (subscription_id, from_status, to_status)
    VALUES (NEW.id, OLD.status, NEW.status);
END;

-- Renewal only if the plan allows it
CREATE TRIGGER trg_sub_renew_guard BEFORE INSERT ON subscriptions
WHEN NEW.renewed_from_id IS NOT NULL
BEGIN
    SELECT RAISE(ABORT, 'This plan does not allow renewal')
    WHERE (SELECT allow_renewal FROM plans WHERE id = NEW.plan_id) = 0;
END;

-- 7b. Invoice lifecycle: Draft -> Confirmed -> Paid (or Cancelled)
CREATE TRIGGER trg_invoice_status_guard BEFORE UPDATE OF status ON invoices
WHEN NEW.status <> OLD.status
BEGIN
    SELECT RAISE(ABORT, 'Invalid invoice status change')
    WHERE (OLD.status || '>' || NEW.status) NOT IN
        ('draft>confirmed','draft>cancelled','confirmed>paid','confirmed>cancelled');
END;

-- lines are frozen after the invoice is confirmed
CREATE TRIGGER trg_inv_lines_lock_ins BEFORE INSERT ON invoice_lines
BEGIN
    SELECT RAISE(ABORT, 'Invoice is not a draft; lines are locked')
    WHERE (SELECT status FROM invoices WHERE id = NEW.invoice_id) <> 'draft';
END;
CREATE TRIGGER trg_inv_lines_lock_upd BEFORE UPDATE ON invoice_lines
BEGIN
    SELECT RAISE(ABORT, 'Invoice is not a draft; lines are locked')
    WHERE (SELECT status FROM invoices WHERE id = OLD.invoice_id) <> 'draft';
END;

-- 7c. Discounts: must be active, in date window, not exhausted; then count the use
CREATE TRIGGER trg_inv_discount_guard BEFORE INSERT ON invoice_discounts
BEGIN
    SELECT RAISE(ABORT, 'Discount is inactive, expired or used up')
    WHERE NOT EXISTS (
        SELECT 1 FROM discounts d WHERE d.id = NEW.discount_id AND d.is_active = 1
          AND (d.valid_from  IS NULL OR d.valid_from  <= date('now'))
          AND (d.valid_until IS NULL OR date('now') <= d.valid_until)
          AND (d.usage_limit IS NULL OR d.usage_count < d.usage_limit));
END;
CREATE TRIGGER trg_inv_discount_count AFTER INSERT ON invoice_discounts
BEGIN
    UPDATE discounts SET usage_count = usage_count + 1 WHERE id = NEW.discount_id;
END;

-- 7d. Payments: validate, then keep invoice balance + status in sync
CREATE TRIGGER trg_payment_guard BEFORE INSERT ON payments
BEGIN
    SELECT RAISE(ABORT, 'Invoice is not open for payment')
    WHERE (SELECT status FROM invoices WHERE id = NEW.invoice_id) <> 'confirmed';
    SELECT RAISE(ABORT, 'Payment belongs to a different customer than the invoice')
    WHERE (SELECT customer_id FROM invoices WHERE id = NEW.invoice_id) <> NEW.customer_id;
    SELECT RAISE(ABORT, 'Payment is more than the amount due')
    WHERE NEW.amount > (SELECT total_amount - amount_paid FROM invoices WHERE id = NEW.invoice_id);
END;

CREATE TRIGGER trg_payment_apply AFTER INSERT ON payments
BEGIN
    UPDATE invoices
       SET amount_paid = amount_paid + NEW.amount,
           status  = CASE WHEN amount_paid + NEW.amount >= total_amount THEN 'paid' ELSE status END,
           paid_at = CASE WHEN amount_paid + NEW.amount >= total_amount
                          THEN strftime('%Y-%m-%d %H:%M:%S','now') ELSE paid_at END
     WHERE id = NEW.invoice_id;
END;

-- =====================================================================
-- 8. VIEWS (finance dashboard, outstanding/overdue, subscription overview)
-- =====================================================================
-- Open invoices with derived overdue / partially-paid state
CREATE VIEW v_outstanding_invoices AS
SELECT i.id, i.invoice_number, i.customer_id, c.name AS customer_name,
       i.subscription_id, i.invoice_date, i.due_date,
       i.total_amount, i.amount_paid, i.total_amount - i.amount_paid AS amount_due,
       CASE WHEN i.due_date < date('now') THEN 1 ELSE 0 END AS is_overdue,
       CASE WHEN i.due_date < date('now')
            THEN CAST(julianday(date('now')) - julianday(i.due_date) AS INTEGER) ELSE 0 END AS days_overdue,
       CASE WHEN i.due_date < date('now') THEN 'overdue'
            WHEN i.amount_paid > 0 THEN 'partially_paid'
            ELSE 'confirmed' END AS display_status
FROM invoices i JOIN customers c ON c.id = i.customer_id
WHERE i.status = 'confirmed';

CREATE VIEW v_overdue_invoices AS
SELECT * FROM v_outstanding_invoices WHERE is_overdue = 1;

CREATE VIEW v_subscription_overview AS
SELECT s.id, s.subscription_number, s.status, s.start_date, s.expiry_date, s.next_billing_date,
       s.customer_id, c.name AS customer_name, s.plan_id, p.name AS plan_name,
       p.billing_frequency, p.billing_interval,
       COALESCE((SELECT SUM(l.quantity * l.unit_price) FROM subscription_lines l
                 WHERE l.subscription_id = s.id AND l.is_active = 1), 0) AS recurring_subtotal
FROM subscriptions s
JOIN customers c ON c.id = s.customer_id
JOIN plans p ON p.id = s.plan_id;

-- Revenue by month: invoiced vs collected
CREATE VIEW v_monthly_revenue AS
SELECT month, SUM(invoiced) AS invoiced, SUM(collected) AS collected FROM (
    SELECT substr(invoice_date,1,7) AS month, total_amount AS invoiced, 0 AS collected
      FROM invoices WHERE status IN ('confirmed','paid')
    UNION ALL
    SELECT substr(payment_date,1,7), 0, amount FROM payments
) GROUP BY month;

-- One row for the finance dashboard cards
CREATE VIEW v_dashboard AS
SELECT
  (SELECT COUNT(*) FROM subscriptions WHERE status = 'active')                          AS active_subscriptions,
  (SELECT COALESCE(SUM(amount),0) FROM payments
     WHERE substr(payment_date,1,7) = strftime('%Y-%m','now'))                          AS revenue_this_month,
  (SELECT COALESCE(SUM(amount),0) FROM payments)                                        AS revenue_total,
  (SELECT COALESCE(SUM(amount_due),0) FROM v_outstanding_invoices)                      AS outstanding_amount,
  (SELECT COUNT(*) FROM v_overdue_invoices)                                             AS overdue_count,
  (SELECT COALESCE(SUM(amount_due),0) FROM v_overdue_invoices)                          AS overdue_amount;

-- =====================================================================
-- 9. SEED
-- =====================================================================
INSERT INTO tax_rates (name, rate) VALUES ('GST 18%', 18), ('GST 5%', 5), ('No tax', 0);
