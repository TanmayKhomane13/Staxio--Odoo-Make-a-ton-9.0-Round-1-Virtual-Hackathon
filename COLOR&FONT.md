:root {
  /* Core Brand & Theme Colors */
  --green: #237b55;        /* Primary action color: buttons, active states, brand accent */
  --green-dark: #185c3e;   /* Hover states, deep brand contrast */
  --green-soft: #eaf4ee;   /* Subtle tint: table row hover, success badge backgrounds */
  --navy: #192b25;         /* Deep dark surfaces, high-contrast headings */

  /* Neutral Base & Surfaces */
  --page: #f6f8f6;         /* Global page body background */
  --surface: #ffffff;      /* Cards, panels, modals, dropdowns */
  --line: #e8ece8;         /* Borders, dividers, subtle separators */

  /* Typography / Ink */
  --ink: #202522;          /* Primary body text & prominent headings */
  --muted: #778079;        /* Secondary/muted text, captions, metadata */

  /* Functional Status & Alerts */
  --danger: #b84242;       /* Errors, overdue invoices, destructive actions */
  --warning: #a56b1d;      /* Warnings, partially paid invoices, pending notices */

  /* Elevation */
  --shadow: 0 16px 50px rgba(24, 48, 36, .08);

  /* Role Badges & Chips */
  --role-admin-bg: #ede9fe;       --role-admin-text: #6d28d9;
  --role-staff-bg: #dbeafe;       --role-staff-text: #1d4ed8;
  --role-customer-bg: #dcfce7;    --role-customer-text: #15803d;
}

---

## Design System & Style Guidelines

### 1. 60-30-10 Distribution Rule
- **60% Dominant Neutral**: Light clean canvas using `--page` (`#f6f8f6`) for backgrounds and `--surface` (`#ffffff`) for cards, data tables, and modal containers.
- **30% Structural & Content**: Sharp text contrast using `--ink` (`#202522`), muted metadata in `--muted` (`#778079`), and crisp dividing lines via `--line` (`#e8ece8`).
- **10% Brand Accent & Focus**: Strategic focus color using `--green` (`#237b55`) and `--green-dark` (`#185c3e`) for primary CTA buttons, active sidebar links, and focused inputs (`box-shadow: 0 0 0 3px var(--green-soft)`).

### 2. Status Badges & Visual Semantics
Never rely on color alone for critical status indication; always accompany colored chips with descriptive labels:
- **Active / Success / Paid**: Background `--green-soft` (`#eaf4ee`), Text `--green-dark` (`#185c3e`).
- **Inactive / Draft / Muted**: Background `--page` (`#f6f8f6`), Text `--muted` (`#778079`).
- **Partially Paid / Pending**: Text `--warning` (`#a56b1d`).
- **Overdue / Canceled / Error**: Text `--danger` (`#b84242`).

### 3. Role Indicator Pills
- **Admin**: Purple accent (`bg: #ede9fe`, `color: #6d28d9`)
- **Staff**: Blue accent (`bg: #dbeafe`, `color: #1d4ed8`)
- **Customer**: Green accent (`bg: #dcfce7`, `color: #15803d`)

---

## Typography & Fonts

### 1. Plus Jakarta Sans (Primary Interface Font)
- **Where used**: Entire application UI across all routes (`/`, `/dashboard`, `/catalog`, `/plans`, `/subscriptions`, `/invoices`, `/payments`, `/portal`, `/login`, `/signup`).
- **Purpose**: All core interface elements — body text, navigation items, buttons, form controls, tables, metrics, and cards.
- **Weights loaded**: `400` (Regular), `500` (Medium), `600` (Semi-bold), `700` (Bold), `800` (Extra-bold).
- **Import**: `https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap`

### 2. Manrope (Brand & Logo Typography)
- **Where used**: Sidebar brand logo (`.brand-mark`), brand name title (`.brand-name`), and auth brand titles.
- **Purpose**: Display typography delivering modern geometric character to the Staxio identity.
- **Weights loaded**: `400`, `500`, `600`, `700`, `800`.
- **CSS Usage**: `font-family: 'Manrope', sans-serif; font-weight: 800; letter-spacing: -1px;`

### 3. DM Sans (Secondary Display Font)
- **Where used**: Preloaded in [`base.html`](app/templates/base.html) for secondary display and alternate headings.
- **Weights loaded**: `400`, `500`, `600`, `700`.
