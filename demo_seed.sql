-- Staxio (hackathon edition) – realistic demo data for schema_lite.sql
-- Money is INTEGER paise.  ₹4,999.00 = 499900
-- Password hashes are placeholders – replace with real bcrypt/argon2 in the app.
-- Execute AFTER schema.sql

PRAGMA foreign_keys = ON;
BEGIN;

-- =====================================================================
-- 1. Users (admin first, then staff, then portal customers)
-- =====================================================================
INSERT INTO users (id, full_name, email, password_hash, role, is_active, created_by) VALUES
(1, 'System Admin',     'admin@staxio.example',
 '$2b$12$PLACEHOLDER_REPLACE_WITH_REAL_BCRYPT_HASH_ADMIN____', 'admin', 1, NULL),
(2, 'Anita Deshmukh',   'anita@staxio.example',
 '$2b$12$PLACEHOLDER_REPLACE_WITH_REAL_BCRYPT_HASH_STAFF____', 'staff', 1, 1),
(3, 'Ravi Sharma',      'ravi@acme.example',
 '$2b$12$PLACEHOLDER_REPLACE_WITH_REAL_BCRYPT_HASH_CUST1____', 'customer', 1, 1),
(4, 'Priya Patel',      'priya@example.com',
 '$2b$12$PLACEHOLDER_REPLACE_WITH_REAL_BCRYPT_HASH_CUST2____', 'customer', 1, 1);

 INSERT INTO users (
    id, full_name, email, password_hash, role, is_active, created_by
) VALUES (
    5,
    'Neha Kulkarni',
    'neha@staxio.example',
    '$2b$12$PLACEHOLDER_REPLACE_WITH_REAL_BCRYPT_HASH_FINANCE',
    'finance_lead',
    1,
    1
);

-- =====================================================================
-- 2. Customers
-- =====================================================================
INSERT INTO customers (id, user_id, name, company_name, email, phone, tax_number, address, payment_terms_days) VALUES
(1, 3, 'Ravi Sharma',  'Acme Tech Pvt Ltd', 'ravi@acme.example',  '+91-9876543210',
 '27AABCA1234A1Z5', '12, IT Park, Hinjewadi, Pune, MH 411057', 30),
(2, 4, 'Priya Patel',  NULL,                'priya@example.com',  '+91-9123456789',
 NULL,              '45, Linking Road, Bandra West, Mumbai, MH 400050', 15),
(3, NULL, 'Demo User', 'Brightloop Demo Client', 'demo@client.example', '+91-9988776655',
 '29AABCD5678B1Z9', '88, MG Road, Bengaluru, KA 560001', 45);

-- =====================================================================
-- 3. Products + Odoo variant (+₹560)
-- =====================================================================
-- tax_rates already seeded by schema: 1=GST 18%, 2=GST 5%, 3=No tax
INSERT INTO products (id, name, product_type, sales_price, cost_price, tax_rate_id, notes, is_active) VALUES
(1, 'Staxio Core Platform',   'software', 499900, 120000, 1, 'Core billing + user management', 1),  -- ₹4,999
(2, 'Analytics Add-on',       'add-on',    99900,  25000, 1, 'Dashboard + export', 1),             -- ₹999
(3, 'Premium Support',        'service',  149900,  40000, 1, '4-hour SLA phone + email', 1),      -- ₹1,499
(4, 'Odoo Integration Pack',  'add-on',        0,      0, 1, 'Price lives on the variant', 1);

INSERT INTO product_variants (id, product_id, attribute_name, attribute_value, price_adjustment) VALUES
(1, 1, 'brand', 'Odoo', 56000);   -- +₹560.00 on Core when brand=Odoo

-- =====================================================================
-- 4. Plans + plan lines
-- =====================================================================
INSERT INTO plans (
    id, name, billing_frequency, billing_interval, price, minimum_quantity,
    allow_early_cancellation, allow_pause, allow_renewal, is_active
) VALUES
(1, 'Standard Monthly', 'monthly', 1, 499900,  1, 1, 1, 1, 1),
(2, 'Standard Yearly',  'yearly',  1, 4999000, 1, 1, 1, 1, 1),
(3, 'Pro Monthly',      'monthly', 1, 599800,  1, 1, 1, 1, 1);  -- Core + Analytics

INSERT INTO plan_lines (plan_id, product_id, variant_id, quantity, unit_price) VALUES
(1, 1, NULL, 1, 499900),
(2, 1, NULL, 1, 4999000),
(3, 1, NULL, 1, 499900),
(3, 2, NULL, 1, 99900);

-- =====================================================================
-- 5. Quotation templates
-- =====================================================================
INSERT INTO quotation_templates (id, name, plan_id, validity_days, is_active) VALUES
(1, 'Standard Monthly Template', 1, 30, 1),
(2, 'Pro Monthly Template',      3, 15, 1);

INSERT INTO quotation_template_lines (template_id, product_id, variant_id, quantity, unit_price) VALUES
(1, 1, NULL, 1, 499900),
(2, 1, NULL, 1, 499900),
(2, 2, NULL, 1, 99900);

-- =====================================================================
-- 6. Discounts
-- =====================================================================
INSERT INTO discounts (
    id, name, code, discount_type, discount_value, minimum_purchase,
    valid_from, valid_until, usage_limit, usage_count, is_active, created_by
) VALUES
(1, 'Welcome 10% off first invoice', 'WELCOME10', 'percentage', 10.0, 0,
 '2025-01-01', '2026-12-31', 200, 0, 1, 1),
(2, 'Flat ₹500 off',                 'FLAT500',   'fixed',      50000, 500000,
 '2025-01-01', '2026-12-31', 50,  0, 1, 1);

-- =====================================================================
-- 7. Subscriptions
--    Insert as draft → update through allowed transitions → active
-- =====================================================================

-- Acme Tech – active monthly Core
INSERT INTO subscriptions (
    id, subscription_number, customer_id, plan_id, template_id, status,
    start_date, next_billing_date, payment_terms_days, created_by
) VALUES
(1, 'SUB-00001', 1, 1, 1, 'draft', '2025-10-01', NULL, 30, 2);

UPDATE subscriptions SET status = 'confirmed' WHERE id = 1;
UPDATE subscriptions SET status = 'active', next_billing_date = '2025-11-01' WHERE id = 1;

INSERT INTO subscription_lines (subscription_id, product_id, variant_id, description, quantity, unit_price, tax_rate_id, is_active) VALUES
(1, 1, NULL, 'Staxio Core Platform – Monthly', 1, 499900, 1, 1);

INSERT INTO subscription_discounts (subscription_id, discount_id) VALUES (1, 1);

-- Priya Patel – active monthly (will have an overdue invoice)
INSERT INTO subscriptions (
    id, subscription_number, customer_id, plan_id, status,
    start_date, next_billing_date, payment_terms_days, created_by
) VALUES
(2, 'SUB-00002', 2, 1, 'draft', '2025-09-01', NULL, 15, 2);

UPDATE subscriptions SET status = 'confirmed' WHERE id = 2;
UPDATE subscriptions SET status = 'active', next_billing_date = '2025-11-01' WHERE id = 2;

INSERT INTO subscription_lines (subscription_id, product_id, description, quantity, unit_price, tax_rate_id, is_active) VALUES
(2, 1, 'Staxio Core Platform – Monthly', 1, 499900, 1, 1);

-- Demo Client – confirmed yearly (not yet activated)
INSERT INTO subscriptions (
    id, subscription_number, customer_id, plan_id, status,
    start_date, expiry_date, payment_terms_days, created_by
) VALUES
(3, 'SUB-00003', 3, 2, 'draft', '2025-11-01', '2026-10-31', 45, 2);

UPDATE subscriptions SET status = 'confirmed' WHERE id = 3;

INSERT INTO subscription_lines (subscription_id, product_id, description, quantity, unit_price, tax_rate_id, is_active) VALUES
(3, 1, 'Staxio Core Platform – Yearly', 1, 4999000, 1, 1);

-- =====================================================================
-- 8. Invoices
--    Must insert as draft → add lines → confirm
--    GST 18% on 499900 = 89982 paise
-- =====================================================================

-- INV-00001  Acme Tech  (partially paid later)
INSERT INTO invoices (
    id, invoice_number, customer_id, subscription_id, status,
    invoice_date, due_date, period_start, period_end,
    customer_name, customer_address, customer_tax_number,
    subtotal, discount_total, tax_total, total_amount, amount_paid
) VALUES
(1, 'INV-00001', 1, 1, 'draft',
 '2025-10-01', '2025-10-31', '2025-10-01', '2025-10-31',
 'Acme Tech Pvt Ltd', '12, IT Park, Hinjewadi, Pune, MH 411057', '27AABCA1234A1Z5',
 499900, 0, 89982, 589882, 0);

INSERT INTO invoice_lines (
    invoice_id, product_id, description, quantity, unit_price,
    discount_amount, tax_name, tax_rate, tax_amount, line_total
) VALUES
(1, 1, 'Staxio Core Platform – Monthly', 1, 499900,
 0, 'GST 18%', 18.0, 89982, 589882);

UPDATE invoices SET status = 'confirmed', sent_at = '2025-10-01 09:20:00' WHERE id = 1;

-- INV-00002  Priya Patel  (left confirmed → shows as overdue in views)
INSERT INTO invoices (
    id, invoice_number, customer_id, subscription_id, status,
    invoice_date, due_date, period_start, period_end,
    customer_name, customer_address, customer_tax_number,
    subtotal, discount_total, tax_total, total_amount, amount_paid
) VALUES
(2, 'INV-00002', 2, 2, 'draft',
 '2025-09-01', '2025-09-16', '2025-09-01', '2025-09-30',
 'Priya Patel', '45, Linking Road, Bandra West, Mumbai, MH 400050', NULL,
 499900, 0, 89982, 589882, 0);

INSERT INTO invoice_lines (
    invoice_id, product_id, description, quantity, unit_price,
    discount_amount, tax_name, tax_rate, tax_amount, line_total
) VALUES
(2, 1, 'Staxio Core Platform – Monthly', 1, 499900,
 0, 'GST 18%', 18.0, 89982, 589882);

UPDATE invoices SET status = 'confirmed', sent_at = '2025-09-01 10:05:00' WHERE id = 2;

-- =====================================================================
-- 9. Partial payment on INV-00001 (₹3,000 of ₹5,898.82)
--    Trigger keeps amount_paid / status in sync
-- =====================================================================
INSERT INTO payments (
    id, payment_number, invoice_id, customer_id, method, amount, payment_date, note, recorded_by
) VALUES
(1, 'PAY-00001', 1, 1, 'upi', 300000, '2025-10-05',
 'Partial UPI payment against INV-00001', 2);
-- After this: INV-00001 stays 'confirmed' with amount_paid=300000 (partially paid in views)

COMMIT;
