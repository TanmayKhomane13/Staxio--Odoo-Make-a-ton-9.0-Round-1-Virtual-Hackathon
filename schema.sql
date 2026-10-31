-- schema.sql  (v1.1.0)
-- Brightloop Software – Subscription Management System
-- SQLite 3.33+ schema (uses UPDATE ... FROM)
--
-- CONVENTIONS
--  * Money: INTEGER minor units (paise / cents). major = minor / 10^minor_unit_digits
--  * Timestamps: 'YYYY-MM-DD HH:MM:SS' UTC.  Dates: 'YYYY-MM-DD'.
--  * Percentages: REAL 0-100.
--  * Line maths (service layer, inside ONE transaction):
--        line_subtotal = quantity * unit_price                (enforced by CHECK)
--        taxable       = line_subtotal - discount_amount
--        line_total    = taxable + tax_amount   (exclusive tax)
--                      = taxable                (inclusive tax)
--    header subtotal/discount_total/tax_total/total_amount = sums of the lines.
--  * Password policy (> 8 chars, upper, lower, special) is validated by the app
--    BEFORE hashing; the DB only guarantees a hash is stored (bcrypt/argon2).
--  * Soft delete via deleted_at on master tables.
--
-- WHAT CHANGED vs 1.0.0 (mapped to the problem statement)
--  Auth/RBAC   : lower-case email check (NOCASE made the old idea impossible), unique
--                token hashes, permissions + role_permissions, users.created_by and
--                triggers so ONLY an admin can create staff/admin accounts, one portal
--                user per customer, extra portal logins via customer_contacts.user_id.
--  Products    : hsn_sac_code, unique variant per attribute, v_variant_prices
--                (e.g. brand=Odoo adds 560 -> 56000 minor units).
--  Plans       : plan_taxes FK was missing, term_periods, date-range checks, unique
--                product/variant per plan, min/max quantity enforced on subscriptions.
--  Lifecycle   : end_date -> expiry_date, status transition table + guard triggers,
--                auto event log, pause / early-cancel flags enforced, tax tables for
--                quotation/subscription lines, missing FKs added (converted_subscription_id).
--  Invoices    : no double billing (unique period per subscription + billing history),
--                lines locked once invoice leaves draft, gapless number_sequences,
--                print tracking, status history trigger, balance CHECK.
--  Discounts   : usage/limit/expiry enforced by triggers, auto-pick view for billing,
--                admin-only creation, fixed/percentage value checks.
--  Payments    : allocation triggers (customer/currency/amount/status), invoice balance
--                and status auto-maintained, refund guard.
--  Reporting   : v_dashboard_summary, v_overdue_invoices, v_monthly_revenue, v_subscription_mrr,
--                dashboard_snapshots, composite/partial indexes for <2s pages.
--  Portal      : subscription_change_requests (pause/cancel/renew/qty), v_portal_user_customers.
--  Housekeeping: redundant indexes dropped (UNIQUE already indexes), updated_at triggers
--                on every table that has the column.

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- =====================================================================
-- 0. Schema version
-- =====================================================================
CREATE TABLE schema_versions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    version     TEXT NOT NULL UNIQUE,
    description TEXT,
    applied_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
INSERT INTO schema_versions (version, description) VALUES
('1.1.0', 'Brightloop schema aligned with problem statement (auth, lifecycle, billing, payments, reporting, portal)');

-- =====================================================================
-- 1. Currencies
-- =====================================================================
CREATE TABLE currencies (
    code              TEXT PRIMARY KEY,
    name              TEXT NOT NULL,
    symbol            TEXT NOT NULL,
    minor_unit_digits INTEGER NOT NULL DEFAULT 2 CHECK (minor_unit_digits BETWEEN 0 AND 4),
    is_active         INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
INSERT INTO currencies (code, name, symbol, minor_unit_digits) VALUES
('INR','Indian Rupee','₹',2),
('USD','US Dollar','$',2);

-- =====================================================================
-- 2. Authentication, roles, staff
-- =====================================================================
CREATE TABLE users (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    full_name             TEXT NOT NULL CHECK (length(trim(full_name)) > 0),
    -- one account per email; stored lower-case (COLLATE BINARY forces a real comparison)
    email                 TEXT NOT NULL COLLATE NOCASE UNIQUE
                          CHECK (email COLLATE BINARY = lower(email) AND email LIKE '_%@_%._%'),
    password_hash         TEXT NOT NULL CHECK (length(password_hash) >= 20),
    role                  TEXT NOT NULL CHECK (role IN ('admin','staff','customer')),
    phone                 TEXT,
    is_active             INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    is_email_verified     INTEGER NOT NULL DEFAULT 0 CHECK (is_email_verified IN (0,1)),
    email_verified_at     TEXT,
    last_login_at         TEXT,
    password_changed_at   TEXT,
    failed_login_attempts INTEGER NOT NULL DEFAULT 0 CHECK (failed_login_attempts >= 0),
    locked_until          TEXT,
    created_by            INTEGER REFERENCES users(id) ON DELETE SET NULL,
    updated_by            INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    deleted_at            TEXT
);
CREATE INDEX idx_users_role   ON users(role) WHERE deleted_at IS NULL;
CREATE INDEX idx_users_active ON users(is_active) WHERE deleted_at IS NULL;

CREATE TABLE password_reset_tokens (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE,
    token_hash   TEXT NOT NULL UNIQUE,            -- hash of the emailed raw token
    expires_at   TEXT NOT NULL,
    used_at      TEXT,
    requested_ip TEXT,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_pwd_reset_user    ON password_reset_tokens(user_id);
CREATE INDEX idx_pwd_reset_expires ON password_reset_tokens(expires_at);

CREATE TABLE email_verification_tokens (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    expires_at TEXT NOT NULL,
    used_at    TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_email_ver_user ON email_verification_tokens(user_id);

-- Role based access: permissions are checked by the app per request.
CREATE TABLE permissions (
    code        TEXT PRIMARY KEY,                 -- e.g. 'invoices.manage'
    description TEXT
);
CREATE TABLE role_permissions (
    role            TEXT NOT NULL CHECK (role IN ('admin','staff','customer')),
    permission_code TEXT NOT NULL REFERENCES permissions(code) ON DELETE CASCADE ON UPDATE CASCADE,
    PRIMARY KEY (role, permission_code)
);

CREATE TABLE staff_profiles (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id       INTEGER NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE ON UPDATE CASCADE,
    employee_code TEXT UNIQUE,
    department    TEXT,
    job_title     TEXT,
    is_active     INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_by    INTEGER REFERENCES users(id) ON DELETE SET NULL,   -- must be an admin
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);

CREATE TABLE audit_logs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id         INTEGER REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE,
    action          TEXT NOT NULL,
    entity_type     TEXT NOT NULL,
    entity_id       INTEGER,
    old_values_json TEXT,
    new_values_json TEXT,
    ip_address      TEXT,
    user_agent      TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_audit_entity  ON audit_logs(entity_type, entity_id);
CREATE INDEX idx_audit_user    ON audit_logs(user_id);
CREATE INDEX idx_audit_created ON audit_logs(created_at);

-- =====================================================================
-- 3. Customers (and customer portal access)
-- =====================================================================
CREATE TABLE customers (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id                 INTEGER REFERENCES users(id) ON DELETE SET NULL ON UPDATE CASCADE, -- primary portal login
    customer_code           TEXT NOT NULL UNIQUE,
    customer_type           TEXT NOT NULL CHECK (customer_type IN ('individual','business')),
    company_name            TEXT,
    contact_person          TEXT,
    email                   TEXT NOT NULL COLLATE NOCASE
                            CHECK (email COLLATE BINARY = lower(email)),
    phone                   TEXT,
    tax_registration_number TEXT,                -- GSTIN / VAT id
    billing_address_line1   TEXT,
    billing_address_line2   TEXT,
    billing_city            TEXT,
    billing_state           TEXT,
    billing_postal_code     TEXT,
    billing_country         TEXT DEFAULT 'IN',
    shipping_address_line1  TEXT,
    shipping_address_line2  TEXT,
    shipping_city           TEXT,
    shipping_state          TEXT,
    shipping_postal_code    TEXT,
    shipping_country        TEXT,
    default_currency        TEXT NOT NULL DEFAULT 'INR' REFERENCES currencies(code),
    payment_terms_days      INTEGER NOT NULL DEFAULT 30 CHECK (payment_terms_days >= 0),
    notes                   TEXT,
    is_active               INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_at              TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at              TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    deleted_at              TEXT,
    CHECK (customer_type <> 'business' OR (company_name IS NOT NULL AND length(trim(company_name)) > 0))
);
CREATE INDEX idx_customers_email   ON customers(email);
CREATE INDEX idx_customers_company ON customers(company_name);
CREATE UNIQUE INDEX uq_customers_user ON customers(user_id) WHERE user_id IS NOT NULL;

CREATE TABLE customer_contacts (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    customer_id       INTEGER NOT NULL REFERENCES customers(id) ON DELETE CASCADE ON UPDATE CASCADE,
    user_id           INTEGER REFERENCES users(id) ON DELETE SET NULL,   -- optional extra portal login
    name              TEXT NOT NULL,
    email             TEXT,
    phone             TEXT,
    designation       TEXT,
    is_primary        INTEGER NOT NULL DEFAULT 0 CHECK (is_primary IN (0,1)),
    receives_invoices INTEGER NOT NULL DEFAULT 1 CHECK (receives_invoices IN (0,1)),
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_cust_contacts_customer ON customer_contacts(customer_id);
CREATE UNIQUE INDEX uq_cust_contacts_user ON customer_contacts(user_id) WHERE user_id IS NOT NULL;
CREATE UNIQUE INDEX uq_cust_primary_contact ON customer_contacts(customer_id) WHERE is_primary = 1;

-- =====================================================================
-- 4. Products, variants, add-ons
-- =====================================================================
CREATE TABLE products (
    id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    product_code             TEXT NOT NULL UNIQUE,
    name                     TEXT NOT NULL,
    product_type             TEXT NOT NULL CHECK (product_type IN ('software','service','add-on','other')),
    description              TEXT,
    hsn_sac_code             TEXT,                       -- GST HSN/SAC
    sales_price              INTEGER NOT NULL DEFAULT 0 CHECK (sales_price >= 0),
    cost_price               INTEGER NOT NULL DEFAULT 0 CHECK (cost_price >= 0),
    currency                 TEXT NOT NULL DEFAULT 'INR' REFERENCES currencies(code),
    is_subscription_eligible INTEGER NOT NULL DEFAULT 1 CHECK (is_subscription_eligible IN (0,1)),
    is_active                INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    notes                    TEXT,
    created_by               INTEGER REFERENCES users(id) ON DELETE SET NULL,
    updated_by               INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at               TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at               TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    deleted_at               TEXT
);
CREATE INDEX idx_products_active ON products(is_active) WHERE deleted_at IS NULL;

CREATE TABLE product_variants (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    product_id       INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE,
    variant_code     TEXT NOT NULL,
    variant_name     TEXT NOT NULL,
    attribute_name   TEXT NOT NULL,                 -- e.g. 'brand'
    attribute_value  TEXT NOT NULL,                 -- e.g. 'Odoo'
    price_adjustment INTEGER NOT NULL DEFAULT 0,    -- minor units; Odoo = +560 (56000 paise)
    cost_adjustment  INTEGER NOT NULL DEFAULT 0,
    currency         TEXT NOT NULL DEFAULT 'INR' REFERENCES currencies(code),
    is_active        INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    UNIQUE (product_id, variant_code),
    UNIQUE (product_id, attribute_name, attribute_value)
);
CREATE INDEX idx_variants_product ON product_variants(product_id);

CREATE TABLE product_addons (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    parent_product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE,
    addon_product_id  INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE,
    default_quantity  INTEGER NOT NULL DEFAULT 1 CHECK (default_quantity > 0),
    is_optional       INTEGER NOT NULL DEFAULT 1 CHECK (is_optional IN (0,1)),
    is_active         INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    UNIQUE (parent_product_id, addon_product_id),
    CHECK (parent_product_id <> addon_product_id)
);
CREATE INDEX idx_addons_parent ON product_addons(parent_product_id);

-- =====================================================================
-- 5. Taxes (admin-defined rules)
-- =====================================================================
CREATE TABLE tax_rates (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL,
    tax_code     TEXT NOT NULL UNIQUE,
    description  TEXT,
    tax_type     TEXT NOT NULL CHECK (tax_type IN ('percentage','fixed')),
    rate         REAL,
    fixed_amount INTEGER,
    currency     TEXT REFERENCES currencies(code),
    sequence     INTEGER NOT NULL DEFAULT 10,       -- order of application (matters for compound)
    is_compound  INTEGER NOT NULL DEFAULT 0 CHECK (is_compound IN (0,1)),
    is_inclusive INTEGER NOT NULL DEFAULT 0 CHECK (is_inclusive IN (0,1)),
    country      TEXT,
    state        TEXT,
    postal_code  TEXT,
    valid_from   TEXT,
    valid_until  TEXT,
    is_active    INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_by   INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    CHECK ((tax_type = 'percentage' AND rate IS NOT NULL AND rate BETWEEN 0 AND 100)
        OR (tax_type = 'fixed' AND fixed_amount IS NOT NULL AND fixed_amount >= 0 AND currency IS NOT NULL)),
    CHECK (valid_until IS NULL OR valid_from IS NULL OR valid_until >= valid_from)
);
CREATE INDEX idx_tax_rates_active ON tax_rates(is_active, valid_from, valid_until);

CREATE TABLE product_taxes (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    product_id  INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE ON UPDATE CASCADE,
    tax_rate_id INTEGER NOT NULL REFERENCES tax_rates(id) ON DELETE RESTRICT ON UPDATE CASCADE,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    UNIQUE (product_id, tax_rate_id)
);

CREATE TABLE plan_taxes (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    plan_id     INTEGER NOT NULL REFERENCES subscription_plans(id) ON DELETE CASCADE ON UPDATE CASCADE,
    tax_rate_id INTEGER NOT NULL REFERENCES tax_rates(id) ON DELETE RESTRICT ON UPDATE CASCADE,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    UNIQUE (plan_id, tax_rate_id)
);

-- =====================================================================
-- 6. Subscription plans
-- =====================================================================
CREATE TABLE subscription_plans (
    id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    plan_code                TEXT NOT NULL UNIQUE,
    name                     TEXT NOT NULL,
    description              TEXT,
    billing_frequency        TEXT NOT NULL CHECK (billing_frequency IN ('daily','weekly','monthly','yearly')),
    billing_interval         INTEGER NOT NULL DEFAULT 1 CHECK (billing_interval > 0),
    term_periods             INTEGER CHECK (term_periods IS NULL OR term_periods > 0), -- billing periods until expiry; NULL = open-ended
    base_price               INTEGER NOT NULL DEFAULT 0 CHECK (base_price >= 0),
    currency                 TEXT NOT NULL DEFAULT 'INR' REFERENCES currencies(code),
    minimum_quantity         INTEGER NOT NULL DEFAULT 1 CHECK (minimum_quantity > 0),
    maximum_quantity         INTEGER CHECK (maximum_quantity IS NULL OR maximum_quantity >= minimum_quantity),
    trial_days               INTEGER NOT NULL DEFAULT 0 CHECK (trial_days >= 0),
    available_from           TEXT,
    available_until          TEXT,
    auto_close_on_expiry     INTEGER NOT NULL DEFAULT 0 CHECK (auto_close_on_expiry IN (0,1)),
    allow_early_cancellation INTEGER NOT NULL DEFAULT 1 CHECK (allow_early_cancellation IN (0,1)),
    allow_pause              INTEGER NOT NULL DEFAULT 1 CHECK (allow_pause IN (0,1)),
    allow_renewal            INTEGER NOT NULL DEFAULT 1 CHECK (allow_renewal IN (0,1)),
    allow_quantity_changes   INTEGER NOT NULL DEFAULT 1 CHECK (allow_quantity_changes IN (0,1)),
    is_active                INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_by               INTEGER REFERENCES users(id) ON DELETE SET NULL,
    updated_by               INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at               TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at               TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    deleted_at               TEXT,
    CHECK (available_until IS NULL OR available_from IS NULL OR available_until >= available_from)
);
CREATE INDEX idx_plans_active ON subscription_plans(is_active, available_from, available_until) WHERE deleted_at IS NULL;
CREATE INDEX idx_plan_taxes_plan ON plan_taxes(plan_id);

CREATE TABLE plan_products (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    plan_id    INTEGER NOT NULL REFERENCES subscription_plans(id) ON DELETE CASCADE ON UPDATE CASCADE,
    product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE RESTRICT ON UPDATE CASCADE,
    variant_id INTEGER REFERENCES product_variants(id) ON DELETE SET NULL ON UPDATE CASCADE,
    quantity   INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit_price INTEGER NOT NULL CHECK (unit_price >= 0),
    is_required INTEGER NOT NULL DEFAULT 1 CHECK (is_required IN (0,1)),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_plan_products_plan ON plan_products(plan_id);
CREATE UNIQUE INDEX uq_plan_products ON plan_products(plan_id, product_id, COALESCE(variant_id, 0));

CREATE TABLE plan_addons (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    plan_id               INTEGER NOT NULL REFERENCES subscription_plans(id) ON DELETE CASCADE ON UPDATE CASCADE,
    product_id            INTEGER NOT NULL REFERENCES products(id) ON DELETE RESTRICT ON UPDATE CASCADE,
    variant_id            INTEGER REFERENCES product_variants(id) ON DELETE SET NULL ON UPDATE CASCADE,
    default_quantity      INTEGER NOT NULL DEFAULT 1 CHECK (default_quantity > 0),
    minimum_quantity      INTEGER NOT NULL DEFAULT 0 CHECK (minimum_quantity >= 0),
    maximum_quantity      INTEGER,
    price_override        INTEGER CHECK (price_override IS NULL OR price_override >= 0),
    is_enabled_by_default INTEGER NOT NULL DEFAULT 0 CHECK (is_enabled_by_default IN (0,1)),
    created_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    CHECK (maximum_quantity IS NULL OR maximum_quantity >= minimum_quantity)
);
CREATE INDEX idx_plan_addons_plan ON plan_addons(plan_id);
CREATE UNIQUE INDEX uq_plan_addons ON plan_addons(plan_id, product_id, COALESCE(variant_id, 0));

-- =====================================================================
-- 7. Quotation templates & quotations
-- =====================================================================
CREATE TABLE quotation_templates (
    id                         INTEGER PRIMARY KEY AUTOINCREMENT,
    template_code              TEXT NOT NULL UNIQUE,
    name                       TEXT NOT NULL,
    description                TEXT,
    plan_id                    INTEGER REFERENCES subscription_plans(id) ON DELETE SET NULL,
    validity_days              INTEGER NOT NULL DEFAULT 30 CHECK (validity_days > 0),
    default_payment_terms_days INTEGER NOT NULL DEFAULT 30 CHECK (default_payment_terms_days >= 0),
    default_currency           TEXT NOT NULL DEFAULT 'INR' REFERENCES currencies(code),
    is_active                  INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_by                 INTEGER REFERENCES users(id) ON DELETE SET NULL,
    updated_by                 INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at                 TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at                 TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);

CREATE TABLE quotation_template_lines (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    template_id         INTEGER NOT NULL REFERENCES quotation_templates(id) ON DELETE CASCADE ON UPDATE CASCADE,
    product_id          INTEGER NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    variant_id          INTEGER REFERENCES product_variants(id) ON DELETE SET NULL,
    description         TEXT,
    quantity            INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit_price          INTEGER NOT NULL CHECK (unit_price >= 0),
    discount_amount     INTEGER NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    discount_percentage REAL NOT NULL DEFAULT 0 CHECK (discount_percentage BETWEEN 0 AND 100),
    line_order          INTEGER NOT NULL DEFAULT 0,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_qt_lines_template ON quotation_template_lines(template_id);

CREATE TABLE quotations (
    id                        INTEGER PRIMARY KEY AUTOINCREMENT,
    quotation_number          TEXT NOT NULL UNIQUE,
    customer_id               INTEGER NOT NULL REFERENCES customers(id) ON DELETE RESTRICT ON UPDATE CASCADE,
    template_id               INTEGER REFERENCES quotation_templates(id) ON DELETE SET NULL,
    plan_id                   INTEGER REFERENCES subscription_plans(id) ON DELETE SET NULL,
    status                    TEXT NOT NULL DEFAULT 'draft'
                              CHECK (status IN ('draft','sent','accepted','rejected','expired','converted')),
    quotation_date            TEXT NOT NULL,
    valid_until               TEXT NOT NULL,          -- quotation_date + template.validity_days
    start_date                TEXT,
    expiry_date               TEXT,
    currency                  TEXT NOT NULL DEFAULT 'INR' REFERENCES currencies(code),
    payment_terms_days        INTEGER NOT NULL DEFAULT 30 CHECK (payment_terms_days >= 0),
    subtotal                  INTEGER NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    discount_total            INTEGER NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
    tax_total                 INTEGER NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
    grand_total               INTEGER NOT NULL DEFAULT 0 CHECK (grand_total >= 0),
    notes                     TEXT,
    terms_and_conditions      TEXT,
    created_by                INTEGER REFERENCES users(id) ON DELETE SET NULL,
    updated_by                INTEGER REFERENCES users(id) ON DELETE SET NULL,
    accepted_at               TEXT,
    rejected_at               TEXT,
    converted_subscription_id INTEGER REFERENCES subscriptions(id) ON DELETE SET NULL,
    created_at                TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at                TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    CHECK (valid_until >= quotation_date),
    CHECK (expiry_date IS NULL OR start_date IS NULL OR expiry_date >= start_date),
    CHECK (status <> 'converted' OR converted_subscription_id IS NOT NULL)
);
CREATE INDEX idx_quotations_customer ON quotations(customer_id, status);
CREATE INDEX idx_quotations_status   ON quotations(status, valid_until);

CREATE TABLE quotation_lines (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    quotation_id         INTEGER NOT NULL REFERENCES quotations(id) ON DELETE CASCADE ON UPDATE CASCADE,
    product_id           INTEGER REFERENCES products(id) ON DELETE SET NULL,
    variant_id           INTEGER REFERENCES product_variants(id) ON DELETE SET NULL,
    description_snapshot TEXT NOT NULL,
    quantity             INTEGER NOT NULL CHECK (quantity > 0),
    unit_price           INTEGER NOT NULL CHECK (unit_price >= 0),
    discount_amount      INTEGER NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    tax_amount           INTEGER NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    line_subtotal        INTEGER NOT NULL CHECK (line_subtotal >= 0),
    line_total           INTEGER NOT NULL CHECK (line_total >= 0),
    created_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    CHECK (line_subtotal = quantity * unit_price),
    CHECK (discount_amount <= line_subtotal)
);
CREATE INDEX idx_quotation_lines_quot ON quotation_lines(quotation_id);

CREATE TABLE quotation_line_taxes (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    quotation_line_id INTEGER NOT NULL REFERENCES quotation_lines(id) ON DELETE CASCADE,
    tax_rate_id       INTEGER REFERENCES tax_rates(id) ON DELETE SET NULL,
    tax_name_snapshot TEXT NOT NULL,
    tax_rate_snapshot REAL,
    taxable_amount    INTEGER NOT NULL CHECK (taxable_amount >= 0),
    tax_amount        INTEGER NOT NULL CHECK (tax_amount >= 0),
    is_inclusive      INTEGER NOT NULL DEFAULT 0 CHECK (is_inclusive IN (0,1))
);
CREATE INDEX idx_quot_line_taxes ON quotation_line_taxes(quotation_line_id);

-- =====================================================================
-- 8. Subscriptions (Draft -> Quotation -> Confirmed -> Active -> Closed)
-- =====================================================================
CREATE TABLE subscriptions (
    id                           INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_number          TEXT NOT NULL UNIQUE,
    customer_id                  INTEGER NOT NULL REFERENCES customers(id) ON DELETE RESTRICT ON UPDATE CASCADE,
    plan_id                      INTEGER NOT NULL REFERENCES subscription_plans(id) ON DELETE RESTRICT ON UPDATE CASCADE,
    quotation_id                 INTEGER REFERENCES quotations(id) ON DELETE SET NULL,
    status                       TEXT NOT NULL DEFAULT 'draft'
                                 CHECK (status IN ('draft','quotation','confirmed','active','paused','cancelled','expired','closed')),
    start_date                   TEXT NOT NULL,
    expiry_date                  TEXT,
    next_billing_date            TEXT,
    last_billed_at               TEXT,
    billing_frequency_snapshot   TEXT NOT NULL CHECK (billing_frequency_snapshot IN ('daily','weekly','monthly','yearly')),
    billing_interval_snapshot    INTEGER NOT NULL DEFAULT 1 CHECK (billing_interval_snapshot > 0),
    currency                     TEXT NOT NULL DEFAULT 'INR' REFERENCES currencies(code),
    quantity                     INTEGER NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit_price                   INTEGER NOT NULL DEFAULT 0 CHECK (unit_price >= 0),
    subtotal                     INTEGER NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    discount_total               INTEGER NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
    tax_total                    INTEGER NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
    total_amount                 INTEGER NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    payment_terms_days           INTEGER NOT NULL DEFAULT 30 CHECK (payment_terms_days >= 0),
    auto_renew                   INTEGER NOT NULL DEFAULT 1 CHECK (auto_renew IN (0,1)),
    -- snapshots of the plan's rules at creation time (copied by the app)
    auto_close_on_expiry         INTEGER NOT NULL DEFAULT 0 CHECK (auto_close_on_expiry IN (0,1)),
    allow_early_cancellation     INTEGER NOT NULL DEFAULT 1 CHECK (allow_early_cancellation IN (0,1)),
    allow_pause                  INTEGER NOT NULL DEFAULT 1 CHECK (allow_pause IN (0,1)),
    allow_renewal                INTEGER NOT NULL DEFAULT 1 CHECK (allow_renewal IN (0,1)),
    pause_started_at             TEXT,
    pause_ends_at                TEXT,
    cancelled_at                 TEXT,
    cancellation_reason          TEXT,
    closed_at                    TEXT,
    renewed_from_subscription_id INTEGER REFERENCES subscriptions(id) ON DELETE SET NULL,
    created_by                   INTEGER REFERENCES users(id) ON DELETE SET NULL,
    updated_by                   INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at                   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at                   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    deleted_at                   TEXT,
    CHECK (expiry_date IS NULL OR expiry_date >= start_date),
    CHECK (status <> 'paused'    OR pause_started_at IS NOT NULL),
    CHECK (status <> 'cancelled' OR cancelled_at IS NOT NULL),
    CHECK (status <> 'closed'    OR closed_at IS NOT NULL),
    CHECK (pause_ends_at IS NULL OR pause_started_at IS NULL OR pause_ends_at >= pause_started_at)
);
CREATE INDEX idx_subs_customer_status ON subscriptions(customer_id, status);
CREATE INDEX idx_subs_plan            ON subscriptions(plan_id);
CREATE INDEX idx_subs_status          ON subscriptions(status, currency);
CREATE INDEX idx_subs_due_billing     ON subscriptions(next_billing_date) WHERE status = 'active';
CREATE INDEX idx_subs_expiry          ON subscriptions(expiry_date) WHERE status IN ('active','paused');
CREATE INDEX idx_subs_quotation       ON subscriptions(quotation_id);

CREATE TABLE subscription_lines (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id      INTEGER NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE ON UPDATE CASCADE,
    product_id           INTEGER REFERENCES products(id) ON DELETE SET NULL,
    variant_id           INTEGER REFERENCES product_variants(id) ON DELETE SET NULL,
    description_snapshot TEXT NOT NULL,
    quantity             INTEGER NOT NULL CHECK (quantity > 0),
    unit_price           INTEGER NOT NULL CHECK (unit_price >= 0),
    cost_price_snapshot  INTEGER CHECK (cost_price_snapshot IS NULL OR cost_price_snapshot >= 0),
    discount_amount      INTEGER NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    discount_percentage  REAL NOT NULL DEFAULT 0 CHECK (discount_percentage BETWEEN 0 AND 100),
    tax_amount           INTEGER NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    line_subtotal        INTEGER NOT NULL CHECK (line_subtotal >= 0),
    line_total           INTEGER NOT NULL CHECK (line_total >= 0),
    start_date           TEXT,
    end_date             TEXT,
    is_addon             INTEGER NOT NULL DEFAULT 0 CHECK (is_addon IN (0,1)),
    is_active            INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),   -- add-ons switched on/off
    created_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    CHECK (line_subtotal = quantity * unit_price),
    CHECK (discount_amount <= line_subtotal),
    CHECK (end_date IS NULL OR start_date IS NULL OR end_date >= start_date)
);
CREATE INDEX idx_sub_lines_sub ON subscription_lines(subscription_id, is_active);

CREATE TABLE subscription_line_taxes (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_line_id INTEGER NOT NULL REFERENCES subscription_lines(id) ON DELETE CASCADE,
    tax_rate_id          INTEGER NOT NULL REFERENCES tax_rates(id) ON DELETE RESTRICT,
    UNIQUE (subscription_line_id, tax_rate_id)
);

CREATE TABLE subscription_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id INTEGER NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE ON UPDATE CASCADE,
    event_type      TEXT NOT NULL,   -- status_change, renewal, pause, resume, cancel, quantity_change ...
    previous_status TEXT,
    new_status      TEXT,
    effective_at    TEXT NOT NULL,
    reason          TEXT,
    metadata_json   TEXT,
    performed_by    INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_sub_events_sub  ON subscription_events(subscription_id, effective_at);
CREATE INDEX idx_sub_events_type ON subscription_events(event_type);

CREATE TABLE subscription_billing_history (
    id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id        INTEGER NOT NULL REFERENCES subscriptions(id) ON DELETE RESTRICT ON UPDATE CASCADE,
    invoice_id             INTEGER REFERENCES invoices(id) ON DELETE SET NULL,
    billing_period_start   TEXT NOT NULL,
    billing_period_end     TEXT NOT NULL,
    scheduled_billing_date TEXT NOT NULL,
    actual_billing_date    TEXT,
    billing_status         TEXT NOT NULL DEFAULT 'pending'
                           CHECK (billing_status IN ('pending','processing','completed','failed','skipped')),
    idempotency_key        TEXT NOT NULL UNIQUE,
    failure_reason         TEXT,
    created_at             TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at             TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    CHECK (billing_period_end >= billing_period_start),
    UNIQUE (subscription_id, billing_period_start, billing_period_end)   -- never bill a period twice
);
CREATE INDEX idx_billing_hist_status ON subscription_billing_history(billing_status, scheduled_billing_date);
CREATE INDEX idx_billing_hist_inv    ON subscription_billing_history(invoice_id);

CREATE TABLE subscription_renewals (
    id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    original_subscription_id INTEGER NOT NULL REFERENCES subscriptions(id) ON DELETE RESTRICT,
    renewed_subscription_id  INTEGER NOT NULL UNIQUE REFERENCES subscriptions(id) ON DELETE RESTRICT,
    renewal_date             TEXT NOT NULL,
    previous_expiry_date     TEXT,
    new_expiry_date          TEXT,
    renewal_amount           INTEGER NOT NULL CHECK (renewal_amount >= 0),
    created_by               INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at               TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    CHECK (original_subscription_id <> renewed_subscription_id)
);
CREATE INDEX idx_renewals_orig ON subscription_renewals(original_subscription_id);

-- Customer self-service: customers request, staff/admin (or auto-rules) approve.
CREATE TABLE subscription_change_requests (
    id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id          INTEGER NOT NULL REFERENCES subscriptions(id) ON DELETE RESTRICT,
    customer_id              INTEGER NOT NULL REFERENCES customers(id) ON DELETE RESTRICT,
    requested_by             INTEGER REFERENCES users(id) ON DELETE SET NULL,
    request_type             TEXT NOT NULL CHECK (request_type IN ('pause','resume','cancel','close','renew','quantity_change')),
    requested_quantity       INTEGER CHECK (requested_quantity IS NULL OR requested_quantity > 0),
    requested_effective_date TEXT,
    reason                   TEXT,
    status                   TEXT NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending','approved','rejected','applied','withdrawn')),
    reviewed_by              INTEGER REFERENCES users(id) ON DELETE SET NULL,
    reviewed_at              TEXT,
    review_note              TEXT,
    created_at               TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at               TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    CHECK (request_type <> 'quantity_change' OR requested_quantity IS NOT NULL)
);
CREATE INDEX idx_change_req_sub    ON subscription_change_requests(subscription_id);
CREATE INDEX idx_change_req_status ON subscription_change_requests(status, created_at);
CREATE INDEX idx_change_req_cust   ON subscription_change_requests(customer_id, status);

-- =====================================================================
-- 9. Discounts (admin only)
-- =====================================================================
CREATE TABLE discount_rules (
    id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    discount_code            TEXT UNIQUE,                 -- NULL for automatic rules
    name                     TEXT NOT NULL,
    description              TEXT,
    discount_type            TEXT NOT NULL CHECK (discount_type IN ('fixed','percentage')),
    discount_value           REAL NOT NULL,               -- minor units when fixed, % when percentage
    currency                 TEXT REFERENCES currencies(code),
    minimum_purchase_amount  INTEGER NOT NULL DEFAULT 0 CHECK (minimum_purchase_amount >= 0),
    minimum_quantity         INTEGER NOT NULL DEFAULT 0 CHECK (minimum_quantity >= 0),
    maximum_discount_amount  INTEGER CHECK (maximum_discount_amount IS NULL OR maximum_discount_amount >= 0),
    valid_from               TEXT,
    valid_until              TEXT,
    usage_limit              INTEGER CHECK (usage_limit IS NULL OR usage_limit > 0),
    usage_count              INTEGER NOT NULL DEFAULT 0 CHECK (usage_count >= 0),
    per_customer_usage_limit INTEGER CHECK (per_customer_usage_limit IS NULL OR per_customer_usage_limit > 0),
    -- 'products': only lines of products in discount_products (all products if none listed)
    -- 'subscriptions': the whole subscription subtotal; 'both': either
    applies_to               TEXT NOT NULL DEFAULT 'both' CHECK (applies_to IN ('products','subscriptions','both')),
    is_active                INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_by               INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at               TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at               TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    CHECK ((discount_type = 'fixed'      AND currency IS NOT NULL AND discount_value >= 0)
        OR (discount_type = 'percentage' AND discount_value >= 0 AND discount_value <= 100)),
    CHECK (valid_until IS NULL OR valid_from IS NULL OR valid_until >= valid_from),
    CHECK (usage_limit IS NULL OR usage_count <= usage_limit)
);
CREATE INDEX idx_discount_active ON discount_rules(is_active, valid_from, valid_until);

CREATE TABLE discount_products (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    discount_rule_id INTEGER NOT NULL REFERENCES discount_rules(id) ON DELETE CASCADE,
    product_id       INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    UNIQUE (discount_rule_id, product_id)
);

-- A rule attached to a subscription; picked up automatically at invoicing time.
CREATE TABLE subscription_discounts (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id  INTEGER NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    discount_rule_id INTEGER NOT NULL REFERENCES discount_rules(id) ON DELETE RESTRICT,
    applied_at       TEXT NOT NULL,
    valid_from       TEXT,
    valid_until      TEXT,
    usage_limit      INTEGER CHECK (usage_limit IS NULL OR usage_limit > 0),  -- e.g. first 3 invoices only
    usage_count      INTEGER NOT NULL DEFAULT 0 CHECK (usage_count >= 0),
    is_active        INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1)),
    created_by       INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    UNIQUE (subscription_id, discount_rule_id),
    CHECK (valid_until IS NULL OR valid_from IS NULL OR valid_until >= valid_from)
);
CREATE INDEX idx_sub_discounts_sub ON subscription_discounts(subscription_id, is_active);

CREATE TABLE discount_applications (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    discount_rule_id    INTEGER NOT NULL REFERENCES discount_rules(id) ON DELETE RESTRICT,
    customer_id         INTEGER NOT NULL REFERENCES customers(id) ON DELETE RESTRICT,
    subscription_id     INTEGER REFERENCES subscriptions(id) ON DELETE SET NULL,
    invoice_id          INTEGER REFERENCES invoices(id) ON DELETE SET NULL,
    invoice_line_id     INTEGER REFERENCES invoice_lines(id) ON DELETE SET NULL,
    discount_amount     INTEGER NOT NULL CHECK (discount_amount >= 0),
    discount_percentage REAL CHECK (discount_percentage IS NULL OR discount_percentage BETWEEN 0 AND 100),
    application_status  TEXT NOT NULL DEFAULT 'applied' CHECK (application_status IN ('applied','reversed','failed')),
    applied_at          TEXT NOT NULL,
    reversed_at         TEXT,
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_disc_app_rule_cust ON discount_applications(discount_rule_id, customer_id, application_status);
CREATE INDEX idx_disc_app_invoice   ON discount_applications(invoice_id);
CREATE INDEX idx_disc_app_sub       ON discount_applications(subscription_id);

-- =====================================================================
-- 10. Invoices
-- =====================================================================
CREATE TABLE invoices (
    id                               INTEGER PRIMARY KEY AUTOINCREMENT,
    invoice_number                   TEXT NOT NULL UNIQUE,
    customer_id                      INTEGER NOT NULL REFERENCES customers(id) ON DELETE RESTRICT ON UPDATE CASCADE,
    subscription_id                  INTEGER REFERENCES subscriptions(id) ON DELETE RESTRICT ON UPDATE CASCADE,
    billing_history_id               INTEGER REFERENCES subscription_billing_history(id) ON DELETE SET NULL,
    invoice_date                     TEXT NOT NULL,
    due_date                         TEXT NOT NULL,
    billing_period_start             TEXT,
    billing_period_end               TEXT,
    status                           TEXT NOT NULL DEFAULT 'draft'
                                     CHECK (status IN ('draft','confirmed','paid','partially_paid','overdue','cancelled','void')),
    currency                         TEXT NOT NULL DEFAULT 'INR' REFERENCES currencies(code),
    subtotal                         INTEGER NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    discount_total                   INTEGER NOT NULL DEFAULT 0 CHECK (discount_total >= 0),
    tax_total                        INTEGER NOT NULL DEFAULT 0 CHECK (tax_total >= 0),
    total_amount                     INTEGER NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    amount_paid                      INTEGER NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
    amount_due                       INTEGER NOT NULL DEFAULT 0 CHECK (amount_due >= 0),
    payment_terms_days               INTEGER NOT NULL DEFAULT 30 CHECK (payment_terms_days >= 0),
    customer_name_snapshot           TEXT,
    customer_email_snapshot          TEXT,
    billing_address_snapshot         TEXT,
    tax_registration_number_snapshot TEXT,
    notes                            TEXT,
    terms_and_conditions             TEXT,
    sent_at                          TEXT,
    last_printed_at                  TEXT,
    print_count                      INTEGER NOT NULL DEFAULT 0 CHECK (print_count >= 0),
    confirmed_at                     TEXT,
    paid_at                          TEXT,
    cancelled_at                     TEXT,
    cancelled_by                     INTEGER REFERENCES users(id) ON DELETE SET NULL,
    cancellation_reason              TEXT,
    created_by                       INTEGER REFERENCES users(id) ON DELETE SET NULL,   -- NULL = system billing job
    updated_by                       INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at                       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at                       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    CHECK (due_date >= invoice_date),
    CHECK (billing_period_end IS NULL OR billing_period_start IS NULL OR billing_period_end >= billing_period_start),
    CHECK (status IN ('cancelled','void') OR amount_due = total_amount - amount_paid),
    CHECK (status <> 'cancelled' OR cancelled_at IS NOT NULL)
);
CREATE INDEX idx_invoices_customer_status ON invoices(customer_id, status, due_date);
CREATE INDEX idx_invoices_subscription    ON invoices(subscription_id);
CREATE INDEX idx_invoices_status_due      ON invoices(status, due_date);
CREATE INDEX idx_invoices_date            ON invoices(invoice_date);
CREATE INDEX idx_invoices_outstanding     ON invoices(due_date) WHERE status IN ('confirmed','partially_paid','overdue');
-- Nothing is billed twice: one live invoice per subscription per billing period.
CREATE UNIQUE INDEX uq_invoice_sub_period ON invoices(subscription_id, billing_period_start, billing_period_end)
    WHERE subscription_id IS NOT NULL AND billing_period_start IS NOT NULL AND status NOT IN ('cancelled','void');

CREATE TABLE invoice_lines (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    invoice_id           INTEGER NOT NULL REFERENCES invoices(id) ON DELETE CASCADE ON UPDATE CASCADE,
    product_id           INTEGER REFERENCES products(id) ON DELETE SET NULL,
    variant_id           INTEGER REFERENCES product_variants(id) ON DELETE SET NULL,
    subscription_line_id INTEGER REFERENCES subscription_lines(id) ON DELETE SET NULL,
    description_snapshot TEXT NOT NULL,
    quantity             INTEGER NOT NULL CHECK (quantity > 0),
    unit_price           INTEGER NOT NULL CHECK (unit_price >= 0),
    cost_price_snapshot  INTEGER CHECK (cost_price_snapshot IS NULL OR cost_price_snapshot >= 0),
    discount_amount      INTEGER NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    discount_percentage  REAL NOT NULL DEFAULT 0 CHECK (discount_percentage BETWEEN 0 AND 100),
    taxable_amount       INTEGER NOT NULL DEFAULT 0 CHECK (taxable_amount >= 0),
    tax_amount           INTEGER NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    line_subtotal        INTEGER NOT NULL CHECK (line_subtotal >= 0),
    line_total           INTEGER NOT NULL CHECK (line_total >= 0),
    service_period_start TEXT,
    service_period_end   TEXT,
    created_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    CHECK (line_subtotal = quantity * unit_price),
    CHECK (discount_amount <= line_subtotal)
);
CREATE INDEX idx_inv_lines_invoice ON invoice_lines(invoice_id);
CREATE INDEX idx_inv_lines_product ON invoice_lines(product_id);

CREATE TABLE invoice_line_taxes (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    invoice_line_id   INTEGER NOT NULL REFERENCES invoice_lines(id) ON DELETE CASCADE ON UPDATE CASCADE,
    tax_rate_id       INTEGER REFERENCES tax_rates(id) ON DELETE SET NULL,
    tax_name_snapshot TEXT NOT NULL,
    tax_rate_snapshot REAL,
    taxable_amount    INTEGER NOT NULL CHECK (taxable_amount >= 0),
    tax_amount        INTEGER NOT NULL CHECK (tax_amount >= 0),
    is_inclusive      INTEGER NOT NULL DEFAULT 0 CHECK (is_inclusive IN (0,1)),
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_inv_line_taxes ON invoice_line_taxes(invoice_line_id);

CREATE TABLE invoice_status_history (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    invoice_id      INTEGER NOT NULL REFERENCES invoices(id) ON DELETE CASCADE ON UPDATE CASCADE,
    previous_status TEXT,
    new_status      TEXT NOT NULL,
    changed_by      INTEGER REFERENCES users(id) ON DELETE SET NULL,
    reason          TEXT,
    changed_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_inv_status_hist ON invoice_status_history(invoice_id, changed_at);

CREATE TABLE invoice_delivery_logs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    invoice_id      INTEGER NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
    delivery_method TEXT NOT NULL,                 -- email, portal, print
    recipient       TEXT,
    delivery_status TEXT NOT NULL CHECK (delivery_status IN ('pending','sent','delivered','failed','bounced')),
    attempt_count   INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    last_attempt_at TEXT,
    delivered_at    TEXT,
    error_message   TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_inv_delivery ON invoice_delivery_logs(invoice_id);

-- =====================================================================
-- 11. Payments, allocations, refunds
-- =====================================================================
CREATE TABLE payments (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    payment_reference     TEXT NOT NULL UNIQUE,
    customer_id           INTEGER NOT NULL REFERENCES customers(id) ON DELETE RESTRICT ON UPDATE CASCADE,
    payment_method        TEXT NOT NULL CHECK (payment_method IN ('cash','bank_transfer','card','upi','cheque','other')),
    amount                INTEGER NOT NULL CHECK (amount > 0),
    currency              TEXT NOT NULL DEFAULT 'INR' REFERENCES currencies(code),
    payment_date          TEXT NOT NULL,
    status                TEXT NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending','completed','failed','refunded','partially_refunded')),
    transaction_reference TEXT,
    gateway_name          TEXT,
    notes                 TEXT,                    -- "a note" from the problem statement
    recorded_by           INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_payments_customer ON payments(customer_id, payment_date);
CREATE INDEX idx_payments_date     ON payments(status, payment_date);
CREATE UNIQUE INDEX uq_payments_txn ON payments(gateway_name, transaction_reference)
    WHERE transaction_reference IS NOT NULL AND gateway_name IS NOT NULL;

-- Links a payment to the invoice(s) it settles. A payment may be split across invoices.
CREATE TABLE payment_allocations (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    payment_id       INTEGER NOT NULL REFERENCES payments(id) ON DELETE RESTRICT ON UPDATE CASCADE,
    invoice_id       INTEGER NOT NULL REFERENCES invoices(id) ON DELETE RESTRICT ON UPDATE CASCADE,
    allocated_amount INTEGER NOT NULL CHECK (allocated_amount > 0),
    allocated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    allocated_by     INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_alloc_payment ON payment_allocations(payment_id);
CREATE INDEX idx_alloc_invoice ON payment_allocations(invoice_id);

CREATE TABLE refunds (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    payment_id            INTEGER NOT NULL REFERENCES payments(id) ON DELETE RESTRICT,
    refund_reference      TEXT NOT NULL UNIQUE,
    amount                INTEGER NOT NULL CHECK (amount > 0),
    refund_date           TEXT NOT NULL,
    status                TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed','failed')),
    reason                TEXT,
    transaction_reference TEXT,
    processed_by          INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_refunds_payment ON refunds(payment_id);

CREATE TABLE payment_events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    payment_id      INTEGER NOT NULL REFERENCES payments(id) ON DELETE CASCADE,
    event_type      TEXT NOT NULL,
    previous_status TEXT,
    new_status      TEXT,
    notes           TEXT,
    metadata_json   TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_pay_events ON payment_events(payment_id);

-- =====================================================================
-- 12. Billing jobs & notifications
-- =====================================================================
-- job_type: generate_invoice, retry_billing, renewal, mark_overdue, expire_subscription,
--           apply_discounts, send_reminder
CREATE TABLE billing_jobs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    job_type        TEXT NOT NULL,
    subscription_id INTEGER REFERENCES subscriptions(id) ON DELETE SET NULL,
    invoice_id      INTEGER REFERENCES invoices(id) ON DELETE SET NULL,
    scheduled_for   TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','processing','completed','failed','cancelled')),
    attempt_count   INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    max_attempts    INTEGER NOT NULL DEFAULT 5 CHECK (max_attempts > 0),
    locked_at       TEXT,
    locked_by       TEXT,
    last_attempt_at TEXT,
    next_retry_at   TEXT,
    completed_at    TEXT,
    last_error      TEXT,
    idempotency_key TEXT UNIQUE,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_billing_jobs_status ON billing_jobs(status, scheduled_for);
CREATE INDEX idx_billing_jobs_retry  ON billing_jobs(next_retry_at) WHERE status = 'failed';
CREATE INDEX idx_billing_jobs_sub    ON billing_jobs(subscription_id);

CREATE TABLE notification_logs (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id           INTEGER REFERENCES users(id) ON DELETE SET NULL,
    customer_id       INTEGER REFERENCES customers(id) ON DELETE SET NULL,
    subscription_id   INTEGER REFERENCES subscriptions(id) ON DELETE SET NULL,
    invoice_id        INTEGER REFERENCES invoices(id) ON DELETE SET NULL,
    notification_type TEXT NOT NULL,           -- invoice_issued, renewal_reminder, overdue, password_reset
    channel           TEXT NOT NULL CHECK (channel IN ('email','sms','in_app')),
    recipient         TEXT,
    status            TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sent','failed','bounced')),
    scheduled_at      TEXT,
    sent_at           TEXT,
    error_message     TEXT,
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);
CREATE INDEX idx_notif_type     ON notification_logs(notification_type, status);
CREATE INDEX idx_notif_customer ON notification_logs(customer_id);

-- =====================================================================
-- 13. System settings, numbering, status workflow, reporting snapshots
-- =====================================================================
CREATE TABLE system_settings (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    setting_key   TEXT NOT NULL UNIQUE,
    setting_value TEXT,
    description   TEXT,
    updated_by    INTEGER REFERENCES users(id) ON DELETE SET NULL,
    updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);

-- Gapless numbering: inside the creating transaction do
--   UPDATE number_sequences SET next_value = next_value + 1 WHERE sequence_key = ? RETURNING prefix, next_value - 1, padding;
CREATE TABLE number_sequences (
    sequence_key TEXT PRIMARY KEY,
    prefix       TEXT NOT NULL,
    next_value   INTEGER NOT NULL DEFAULT 1 CHECK (next_value > 0),
    padding      INTEGER NOT NULL DEFAULT 5 CHECK (padding >= 0),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now'))
);

CREATE TABLE status_transitions (
    entity_type TEXT NOT NULL CHECK (entity_type IN ('subscription','invoice')),
    from_status TEXT NOT NULL,
    to_status   TEXT NOT NULL,
    PRIMARY KEY (entity_type, from_status, to_status)
);

-- Pre-aggregated daily numbers so the finance dashboard stays fast with thousands of rows.
-- Filled nightly by a billing_job; live views below are used for "today".
CREATE TABLE dashboard_snapshots (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    snapshot_date         TEXT NOT NULL,
    currency              TEXT NOT NULL REFERENCES currencies(code),
    active_subscriptions  INTEGER NOT NULL DEFAULT 0,
    mrr_minor             INTEGER NOT NULL DEFAULT 0,
    invoiced_minor        INTEGER NOT NULL DEFAULT 0,
    collected_minor       INTEGER NOT NULL DEFAULT 0,
    outstanding_minor     INTEGER NOT NULL DEFAULT 0,
    overdue_count         INTEGER NOT NULL DEFAULT 0,
    overdue_minor         INTEGER NOT NULL DEFAULT 0,
    created_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%d %H:%M:%S','now')),
    UNIQUE (snapshot_date, currency)
);

-- =====================================================================
-- 15. Triggers – updated_at
-- =====================================================================
CREATE TRIGGER trg_currencies_upd    AFTER UPDATE ON currencies    WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE currencies    SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE code = NEW.code; END;
CREATE TRIGGER trg_users_upd         AFTER UPDATE ON users         WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE users         SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_staff_upd         AFTER UPDATE ON staff_profiles WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE staff_profiles SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_customers_upd     AFTER UPDATE ON customers     WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE customers     SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_contacts_upd      AFTER UPDATE ON customer_contacts WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE customer_contacts SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_products_upd      AFTER UPDATE ON products      WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE products      SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_variants_upd      AFTER UPDATE ON product_variants WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE product_variants SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_tax_rates_upd     AFTER UPDATE ON tax_rates     WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE tax_rates     SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_plans_upd         AFTER UPDATE ON subscription_plans WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE subscription_plans SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_plan_products_upd AFTER UPDATE ON plan_products WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE plan_products SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_plan_addons_upd   AFTER UPDATE ON plan_addons   WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE plan_addons   SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_qtpl_upd          AFTER UPDATE ON quotation_templates WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE quotation_templates SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_qtpl_lines_upd    AFTER UPDATE ON quotation_template_lines WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE quotation_template_lines SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_quotations_upd    AFTER UPDATE ON quotations    WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE quotations    SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_quot_lines_upd    AFTER UPDATE ON quotation_lines WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE quotation_lines SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_subs_upd          AFTER UPDATE ON subscriptions WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE subscriptions SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_sub_lines_upd     AFTER UPDATE ON subscription_lines WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE subscription_lines SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_billing_hist_upd  AFTER UPDATE ON subscription_billing_history WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE subscription_billing_history SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_change_req_upd    AFTER UPDATE ON subscription_change_requests WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE subscription_change_requests SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_discount_rules_upd AFTER UPDATE ON discount_rules WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE discount_rules SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_sub_discounts_upd AFTER UPDATE ON subscription_discounts WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE subscription_discounts SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_invoices_upd      AFTER UPDATE ON invoices      WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE invoices      SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_inv_lines_upd     AFTER UPDATE ON invoice_lines WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE invoice_lines SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_payments_upd      AFTER UPDATE ON payments      WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE payments      SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_refunds_upd       AFTER UPDATE ON refunds       WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE refunds       SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_billing_jobs_upd  AFTER UPDATE ON billing_jobs  WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE billing_jobs  SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;
CREATE TRIGGER trg_settings_upd      AFTER UPDATE ON system_settings WHEN NEW.updated_at = OLD.updated_at BEGIN UPDATE system_settings SET updated_at = strftime('%Y-%m-%d %H:%M:%S','now') WHERE id = NEW.id; END;

-- =====================================================================
-- 16. Triggers – access control (only an admin adds staff / creates discounts)
-- =====================================================================
-- Bootstrap: the very first admin may be created without a creator.
CREATE TRIGGER trg_users_privileged_insert BEFORE INSERT ON users
WHEN NEW.role IN ('admin','staff')
BEGIN
    SELECT RAISE(ABORT, 'only an admin can create admin or staff accounts')
    WHERE EXISTS (SELECT 1 FROM users WHERE role = 'admin')
      AND NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.created_by AND role = 'admin'
                      AND is_active = 1 AND deleted_at IS NULL);
END;

CREATE TRIGGER trg_users_role_change BEFORE UPDATE OF role ON users
WHEN NEW.role <> OLD.role
BEGIN
    SELECT RAISE(ABORT, 'only an admin can change a user role')
    WHERE NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.updated_by AND role = 'admin'
                      AND is_active = 1 AND deleted_at IS NULL);
END;

CREATE TRIGGER trg_staff_profiles_admin_only BEFORE INSERT ON staff_profiles
BEGIN
    SELECT RAISE(ABORT, 'staff profile requires a user with role staff')
    WHERE NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.user_id AND role = 'staff');
    SELECT RAISE(ABORT, 'only an admin can add staff')
    WHERE NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.created_by AND role = 'admin'
                      AND is_active = 1 AND deleted_at IS NULL);
END;

CREATE TRIGGER trg_discount_rules_admin_only BEFORE INSERT ON discount_rules
BEGIN
    SELECT RAISE(ABORT, 'only an admin can create discount rules')
    WHERE NOT EXISTS (SELECT 1 FROM users WHERE id = NEW.created_by AND role = 'admin'
                      AND is_active = 1 AND deleted_at IS NULL);
END;

-- =====================================================================
-- 17. Triggers – subscription lifecycle
-- =====================================================================
CREATE TRIGGER trg_subs_status_guard BEFORE UPDATE OF status ON subscriptions
WHEN NEW.status <> OLD.status
BEGIN
    SELECT RAISE(ABORT, 'invalid subscription status transition')
    WHERE NOT EXISTS (SELECT 1 FROM status_transitions
                      WHERE entity_type = 'subscription' AND from_status = OLD.status AND to_status = NEW.status);
    SELECT RAISE(ABORT, 'this subscription cannot be paused')
    WHERE NEW.status = 'paused' AND NEW.allow_pause = 0;
    SELECT RAISE(ABORT, 'this subscription cannot be closed or cancelled before expiry')
    WHERE NEW.status IN ('cancelled','closed') AND OLD.status IN ('active','paused')
      AND NEW.allow_early_cancellation = 0
      AND NEW.expiry_date IS NOT NULL AND date('now') < NEW.expiry_date;
END;

CREATE TRIGGER trg_subs_status_event AFTER UPDATE OF status ON subscriptions
WHEN NEW.status <> OLD.status
BEGIN
    INSERT INTO subscription_events (subscription_id, event_type, previous_status, new_status, effective_at, reason, performed_by)
    VALUES (NEW.id, 'status_change', OLD.status, NEW.status, strftime('%Y-%m-%d %H:%M:%S','now'),
            NEW.cancellation_reason, NEW.updated_by);
END;

-- Plan min/max quantity
CREATE TRIGGER trg_subs_qty_ins BEFORE INSERT ON subscriptions
BEGIN
    SELECT RAISE(ABORT, 'quantity outside plan minimum/maximum')
    WHERE EXISTS (SELECT 1 FROM subscription_plans p WHERE p.id = NEW.plan_id
                  AND (NEW.quantity < p.minimum_quantity
                       OR (p.maximum_quantity IS NOT NULL AND NEW.quantity > p.maximum_quantity)));
END;
CREATE TRIGGER trg_subs_qty_upd BEFORE UPDATE OF quantity ON subscriptions
WHEN NEW.quantity <> OLD.quantity
BEGIN
    SELECT RAISE(ABORT, 'quantity outside plan minimum/maximum')
    WHERE EXISTS (SELECT 1 FROM subscription_plans p WHERE p.id = NEW.plan_id
                  AND (NEW.quantity < p.minimum_quantity
                       OR (p.maximum_quantity IS NOT NULL AND NEW.quantity > p.maximum_quantity)));
    SELECT RAISE(ABORT, 'plan does not allow quantity changes')
    WHERE EXISTS (SELECT 1 FROM subscription_plans p WHERE p.id = NEW.plan_id AND p.allow_quantity_changes = 0);
END;

-- Renewals only where allowed
CREATE TRIGGER trg_renewals_guard BEFORE INSERT ON subscription_renewals
BEGIN
    SELECT RAISE(ABORT, 'renewal not allowed for this subscription')
    WHERE EXISTS (SELECT 1 FROM subscriptions WHERE id = NEW.original_subscription_id AND allow_renewal = 0);
END;

-- Portal requests must respect the plan rules and belong to the subscription's customer
CREATE TRIGGER trg_change_req_guard BEFORE INSERT ON subscription_change_requests
BEGIN
    SELECT RAISE(ABORT, 'subscription does not belong to this customer')
    WHERE NOT EXISTS (SELECT 1 FROM subscriptions WHERE id = NEW.subscription_id AND customer_id = NEW.customer_id);
    SELECT RAISE(ABORT, 'pause not allowed')
    WHERE NEW.request_type = 'pause'
      AND EXISTS (SELECT 1 FROM subscriptions WHERE id = NEW.subscription_id AND allow_pause = 0);
    SELECT RAISE(ABORT, 'renewal not allowed')
    WHERE NEW.request_type = 'renew'
      AND EXISTS (SELECT 1 FROM subscriptions WHERE id = NEW.subscription_id AND allow_renewal = 0);
    SELECT RAISE(ABORT, 'early cancellation not allowed')
    WHERE NEW.request_type IN ('cancel','close')
      AND EXISTS (SELECT 1 FROM subscriptions WHERE id = NEW.subscription_id AND allow_early_cancellation = 0
                  AND expiry_date IS NOT NULL AND date('now') < expiry_date);
    SELECT RAISE(ABORT, 'quantity changes not allowed')
    WHERE NEW.request_type = 'quantity_change'
      AND EXISTS (SELECT 1 FROM subscriptions s JOIN subscription_plans p ON p.id = s.plan_id
                  WHERE s.id = NEW.subscription_id AND p.allow_quantity_changes = 0);
END;

-- =====================================================================
-- 18. Triggers – invoices
-- =====================================================================
CREATE TRIGGER trg_invoices_status_guard BEFORE UPDATE OF status ON invoices
WHEN NEW.status <> OLD.status
BEGIN
    SELECT RAISE(ABORT, 'invalid invoice status transition')
    WHERE NOT EXISTS (SELECT 1 FROM status_transitions
                      WHERE entity_type = 'invoice' AND from_status = OLD.status AND to_status = NEW.status);
END;

CREATE TRIGGER trg_invoices_status_history AFTER UPDATE OF status ON invoices
WHEN NEW.status <> OLD.status
BEGIN
    INSERT INTO invoice_status_history (invoice_id, previous_status, new_status, changed_by, reason)
    VALUES (NEW.id, OLD.status, NEW.status, NEW.updated_by, NEW.cancellation_reason);
END;

-- Lines are frozen once the invoice is confirmed (nothing "goes out wrong" afterwards).
CREATE TRIGGER trg_inv_lines_lock_ins BEFORE INSERT ON invoice_lines
BEGIN
    SELECT RAISE(ABORT, 'invoice is not in draft; lines are locked')
    WHERE (SELECT status FROM invoices WHERE id = NEW.invoice_id) <> 'draft';
END;
CREATE TRIGGER trg_inv_lines_lock_upd BEFORE UPDATE ON invoice_lines
BEGIN
    SELECT RAISE(ABORT, 'invoice is not in draft; lines are locked')
    WHERE (SELECT status FROM invoices WHERE id = OLD.invoice_id) <> 'draft';
END;
CREATE TRIGGER trg_inv_lines_lock_del BEFORE DELETE ON invoice_lines
WHEN EXISTS (SELECT 1 FROM invoices WHERE id = OLD.invoice_id)   -- allows ON DELETE CASCADE of drafts only via app
BEGIN
    SELECT RAISE(ABORT, 'invoice is not in draft; lines are locked')
    WHERE (SELECT status FROM invoices WHERE id = OLD.invoice_id) <> 'draft';
END;

-- =====================================================================
-- 19. Triggers – discounts (expiry / usage limit enforcement)
-- =====================================================================
CREATE TRIGGER trg_disc_app_guard BEFORE INSERT ON discount_applications
WHEN NEW.application_status = 'applied'
BEGIN
    SELECT RAISE(ABORT, 'discount rule is inactive, expired or exhausted')
    WHERE NOT EXISTS (
        SELECT 1 FROM discount_rules r
        WHERE r.id = NEW.discount_rule_id AND r.is_active = 1
          AND (r.valid_from  IS NULL OR r.valid_from  <= date(NEW.applied_at))
          AND (r.valid_until IS NULL OR date(NEW.applied_at) <= r.valid_until)
          AND (r.usage_limit IS NULL OR r.usage_count < r.usage_limit));
    SELECT RAISE(ABORT, 'per-customer discount usage limit reached')
    WHERE EXISTS (
        SELECT 1 FROM discount_rules r
        WHERE r.id = NEW.discount_rule_id AND r.per_customer_usage_limit IS NOT NULL
          AND (SELECT COUNT(*) FROM discount_applications a
               WHERE a.discount_rule_id = r.id AND a.customer_id = NEW.customer_id
                 AND a.application_status = 'applied') >= r.per_customer_usage_limit);
END;

CREATE TRIGGER trg_disc_app_count_ins AFTER INSERT ON discount_applications
WHEN NEW.application_status = 'applied'
BEGIN
    UPDATE discount_rules SET usage_count = usage_count + 1 WHERE id = NEW.discount_rule_id;
    UPDATE subscription_discounts SET usage_count = usage_count + 1
     WHERE subscription_id = NEW.subscription_id AND discount_rule_id = NEW.discount_rule_id;
END;

CREATE TRIGGER trg_disc_app_count_rev AFTER UPDATE OF application_status ON discount_applications
WHEN OLD.application_status = 'applied' AND NEW.application_status = 'reversed'
BEGIN
    UPDATE discount_rules SET usage_count = MAX(usage_count - 1, 0) WHERE id = NEW.discount_rule_id;
    UPDATE subscription_discounts SET usage_count = MAX(usage_count - 1, 0)
     WHERE subscription_id = NEW.subscription_id AND discount_rule_id = NEW.discount_rule_id;
END;

-- =====================================================================
-- 20. Triggers – payments, allocations, refunds
-- =====================================================================
CREATE TRIGGER trg_alloc_guard BEFORE INSERT ON payment_allocations
BEGIN
    SELECT RAISE(ABORT, 'only completed payments can be allocated')
    WHERE (SELECT status FROM payments WHERE id = NEW.payment_id) <> 'completed';
    SELECT RAISE(ABORT, 'payment and invoice belong to different customers')
    WHERE (SELECT customer_id FROM payments WHERE id = NEW.payment_id)
       <> (SELECT customer_id FROM invoices WHERE id = NEW.invoice_id);
    SELECT RAISE(ABORT, 'payment and invoice currencies differ')
    WHERE (SELECT currency FROM payments WHERE id = NEW.payment_id)
       <> (SELECT currency FROM invoices WHERE id = NEW.invoice_id);
    SELECT RAISE(ABORT, 'invoice is not open for payment')
    WHERE (SELECT status FROM invoices WHERE id = NEW.invoice_id) NOT IN ('confirmed','partially_paid','overdue');
    SELECT RAISE(ABORT, 'allocation exceeds invoice amount due')
    WHERE NEW.allocated_amount > (SELECT amount_due FROM invoices WHERE id = NEW.invoice_id);
    SELECT RAISE(ABORT, 'allocations exceed payment amount')
    WHERE NEW.allocated_amount + (SELECT COALESCE(SUM(allocated_amount),0) FROM payment_allocations WHERE payment_id = NEW.payment_id)
          > (SELECT amount FROM payments WHERE id = NEW.payment_id);
END;

CREATE TRIGGER trg_alloc_immutable BEFORE UPDATE ON payment_allocations
BEGIN
    SELECT RAISE(ABORT, 'allocations are immutable; delete and re-create');
END;

-- Keep invoice balance and paid/partially_paid status in sync with allocations.
CREATE TRIGGER trg_alloc_sync_ins AFTER INSERT ON payment_allocations
BEGIN
    UPDATE invoices SET
        amount_paid = s.paid,
        amount_due  = invoices.total_amount - s.paid,
        status = CASE
            WHEN invoices.status IN ('draft','cancelled','void') THEN invoices.status
            WHEN invoices.total_amount - s.paid <= 0 THEN 'paid'
            WHEN s.paid > 0 THEN 'partially_paid'
            WHEN invoices.due_date < date('now') THEN 'overdue'
            ELSE 'confirmed' END,
        paid_at = CASE WHEN invoices.status NOT IN ('draft','cancelled','void') AND invoices.total_amount - s.paid <= 0
                       THEN COALESCE(invoices.paid_at, strftime('%Y-%m-%d %H:%M:%S','now')) ELSE NULL END
    FROM (SELECT COALESCE(SUM(allocated_amount),0) AS paid FROM payment_allocations WHERE invoice_id = NEW.invoice_id) AS s
    WHERE invoices.id = NEW.invoice_id;
END;

CREATE TRIGGER trg_alloc_sync_del AFTER DELETE ON payment_allocations
BEGIN
    UPDATE invoices SET
        amount_paid = s.paid,
        amount_due  = invoices.total_amount - s.paid,
        status = CASE
            WHEN invoices.status IN ('draft','cancelled','void') THEN invoices.status
            WHEN invoices.total_amount - s.paid <= 0 THEN 'paid'
            WHEN s.paid > 0 THEN 'partially_paid'
            WHEN invoices.due_date < date('now') THEN 'overdue'
            ELSE 'confirmed' END,
        paid_at = CASE WHEN invoices.status NOT IN ('draft','cancelled','void') AND invoices.total_amount - s.paid <= 0
                       THEN invoices.paid_at ELSE NULL END
    FROM (SELECT COALESCE(SUM(allocated_amount),0) AS paid FROM payment_allocations WHERE invoice_id = OLD.invoice_id) AS s
    WHERE invoices.id = OLD.invoice_id;
END;

CREATE TRIGGER trg_refund_guard BEFORE INSERT ON refunds
BEGIN
    SELECT RAISE(ABORT, 'refunds exceed the original payment')
    WHERE NEW.amount + (SELECT COALESCE(SUM(amount),0) FROM refunds WHERE payment_id = NEW.payment_id AND status <> 'failed')
          > (SELECT amount FROM payments WHERE id = NEW.payment_id);
END;

CREATE TRIGGER trg_refund_status_ins AFTER INSERT ON refunds
WHEN NEW.status = 'completed'
BEGIN
    UPDATE payments SET status = CASE
        WHEN (SELECT COALESCE(SUM(amount),0) FROM refunds WHERE payment_id = NEW.payment_id AND status = 'completed') >= amount THEN 'refunded'
        ELSE 'partially_refunded' END
    WHERE id = NEW.payment_id AND status IN ('completed','partially_refunded');
END;

CREATE TRIGGER trg_refund_status_upd AFTER UPDATE OF status ON refunds
WHEN NEW.status = 'completed' AND OLD.status <> 'completed'
BEGIN
    UPDATE payments SET status = CASE
        WHEN (SELECT COALESCE(SUM(amount),0) FROM refunds WHERE payment_id = NEW.payment_id AND status = 'completed') >= amount THEN 'refunded'
        ELSE 'partially_refunded' END
    WHERE id = NEW.payment_id AND status IN ('completed','partially_refunded');
END;

-- =====================================================================
-- 21. Views – billing, portal, finance dashboard
-- =====================================================================
-- Effective variant price (e.g. brand=Odoo -> +560.00)
CREATE VIEW v_variant_prices AS
SELECT v.id AS variant_id, p.id AS product_id, p.product_code, p.name AS product_name,
       v.variant_code, v.variant_name, v.attribute_name, v.attribute_value,
       p.sales_price + v.price_adjustment AS sales_price,
       p.cost_price  + v.cost_adjustment  AS cost_price,
       p.currency
FROM product_variants v JOIN products p ON p.id = v.product_id
WHERE v.is_active = 1 AND p.is_active = 1 AND p.deleted_at IS NULL;

-- Everyone on the team can see where a subscription stands.
CREATE VIEW v_subscription_overview AS
SELECT s.id, s.subscription_number, s.status, s.start_date, s.expiry_date, s.next_billing_date,
       s.customer_id, c.customer_code, COALESCE(c.company_name, c.contact_person) AS customer_name,
       s.plan_id, pl.plan_code, pl.name AS plan_name,
       s.billing_frequency_snapshot AS billing_frequency, s.billing_interval_snapshot AS billing_interval,
       s.currency, s.quantity, s.total_amount, s.payment_terms_days
FROM subscriptions s
JOIN customers c ON c.id = s.customer_id
JOIN subscription_plans pl ON pl.id = s.plan_id
WHERE s.deleted_at IS NULL;

-- Subscriptions the billing job must invoice now (and not already invoiced for that period).
CREATE VIEW v_subscriptions_due_for_billing AS
SELECT s.*
FROM subscriptions s
WHERE s.status = 'active' AND s.deleted_at IS NULL
  AND s.next_billing_date <= date('now')
  AND (s.expiry_date IS NULL OR s.next_billing_date <= s.expiry_date)
  AND NOT EXISTS (SELECT 1 FROM subscription_billing_history h
                  WHERE h.subscription_id = s.id AND h.billing_period_start = s.next_billing_date
                    AND h.billing_status IN ('processing','completed'));

-- Discounts that should show up on the next invoice automatically.
CREATE VIEW v_applicable_subscription_discounts AS
SELECT sd.subscription_id, sd.id AS subscription_discount_id, r.*
FROM subscription_discounts sd
JOIN discount_rules r ON r.id = sd.discount_rule_id
WHERE sd.is_active = 1 AND r.is_active = 1
  AND (sd.valid_from  IS NULL OR sd.valid_from  <= date('now'))
  AND (sd.valid_until IS NULL OR date('now') <= sd.valid_until)
  AND (sd.usage_limit IS NULL OR sd.usage_count < sd.usage_limit)
  AND (r.valid_from   IS NULL OR r.valid_from   <= date('now'))
  AND (r.valid_until  IS NULL OR date('now') <= r.valid_until)
  AND (r.usage_limit  IS NULL OR r.usage_count  <  r.usage_limit);

-- Which customers a logged-in portal user may see (filter every portal query on this).
CREATE VIEW v_portal_user_customers AS
SELECT user_id, id AS customer_id FROM customers WHERE user_id IS NOT NULL AND deleted_at IS NULL
UNION
SELECT cc.user_id, cc.customer_id FROM customer_contacts cc
  JOIN customers c ON c.id = cc.customer_id AND c.deleted_at IS NULL
 WHERE cc.user_id IS NOT NULL;

-- Outstanding / overdue (date-based, so correct even before the nightly overdue job runs)
CREATE VIEW v_outstanding_invoices AS
SELECT i.id, i.invoice_number, i.customer_id, COALESCE(c.company_name, c.contact_person) AS customer_name,
       i.subscription_id, i.invoice_date, i.due_date, i.currency,
       i.total_amount, i.amount_paid, i.amount_due, i.status,
       CASE WHEN i.due_date < date('now') THEN 1 ELSE 0 END AS is_overdue,
       CASE WHEN i.due_date < date('now') THEN CAST(julianday(date('now')) - julianday(i.due_date) AS INTEGER) ELSE 0 END AS days_overdue
FROM invoices i JOIN customers c ON c.id = i.customer_id
WHERE i.status IN ('confirmed','partially_paid','overdue') AND i.amount_due > 0;

CREATE VIEW v_overdue_invoices AS
SELECT * FROM v_outstanding_invoices WHERE is_overdue = 1;

-- MRR per subscription (excl. tax, after discounts, normalised to a month)
CREATE VIEW v_subscription_mrr AS
SELECT s.id AS subscription_id, s.customer_id, s.currency, s.status,
       CAST(ROUND((s.subtotal - s.discount_total) *
            CASE s.billing_frequency_snapshot
                 WHEN 'monthly' THEN 1.0 WHEN 'yearly' THEN 1.0/12
                 WHEN 'weekly'  THEN 52.0/12 WHEN 'daily' THEN 365.0/12 END
            / s.billing_interval_snapshot) AS INTEGER) AS mrr_minor
FROM subscriptions s WHERE s.deleted_at IS NULL;

-- Revenue by month: invoiced vs collected vs refunded, per currency.
CREATE VIEW v_monthly_revenue AS
SELECT month, currency, SUM(invoiced) AS invoiced_minor, SUM(collected) AS collected_minor, SUM(refunded) AS refunded_minor
FROM (
    SELECT substr(invoice_date,1,7) AS month, currency, total_amount AS invoiced, 0 AS collected, 0 AS refunded
      FROM invoices WHERE status IN ('confirmed','paid','partially_paid','overdue')
    UNION ALL
    SELECT substr(payment_date,1,7), currency, 0, amount, 0
      FROM payments WHERE status IN ('completed','partially_refunded','refunded')
    UNION ALL
    SELECT substr(r.refund_date,1,7), p.currency, 0, 0, r.amount
      FROM refunds r JOIN payments p ON p.id = r.payment_id WHERE r.status = 'completed'
) GROUP BY month, currency;

-- One-row-per-currency finance summary: active subs, MRR, revenue this month, owed, overdue.
CREATE VIEW v_dashboard_summary AS
SELECT c.code AS currency,
  (SELECT COUNT(*) FROM subscriptions s WHERE s.status = 'active' AND s.currency = c.code AND s.deleted_at IS NULL) AS active_subscriptions,
  (SELECT COALESCE(SUM(m.mrr_minor),0) FROM v_subscription_mrr m WHERE m.status = 'active' AND m.currency = c.code) AS mrr_minor,
  (SELECT COALESCE(SUM(p.amount),0) FROM payments p
     WHERE p.currency = c.code AND p.status IN ('completed','partially_refunded','refunded')
       AND substr(p.payment_date,1,7) = strftime('%Y-%m','now')) AS collected_this_month_minor,
  (SELECT COALESCE(SUM(i.amount_due),0) FROM invoices i
     WHERE i.currency = c.code AND i.status IN ('confirmed','partially_paid','overdue')) AS outstanding_minor,
  (SELECT COUNT(*) FROM invoices i
     WHERE i.currency = c.code AND i.status IN ('confirmed','partially_paid','overdue')
       AND i.amount_due > 0 AND i.due_date < date('now')) AS overdue_count,
  (SELECT COALESCE(SUM(i.amount_due),0) FROM invoices i
     WHERE i.currency = c.code AND i.status IN ('confirmed','partially_paid','overdue')
       AND i.amount_due > 0 AND i.due_date < date('now')) AS overdue_minor
FROM currencies c WHERE c.is_active = 1;

