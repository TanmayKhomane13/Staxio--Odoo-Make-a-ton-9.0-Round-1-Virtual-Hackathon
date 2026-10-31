from decimal import Decimal, ROUND_HALF_UP

def money_round(value):
    """Round a Decimal monetary value to the nearest integer paise."""
    return int(
        Decimal(str(value)).quantize(
            Decimal("1"),
            rounding=ROUND_HALF_UP
        )
    )


def calculate_tax(taxable_amount, tax_rate):
    """Calculate exclusive tax in paise."""
    amount = Decimal(int(taxable_amount))
    rate = Decimal(str(tax_rate or 0))

    return money_round(amount * rate / Decimal("100"))


def calculate_line_amount(quantity, unit_price):
    """Return quantity multiplied by unit price in paise."""
    quantity = int(quantity)
    unit_price = int(unit_price)

    if quantity <= 0:
        raise ValueError("Quantity must be greater than zero.")

    if unit_price < 0:
        raise ValueError("Unit price cannot be negative.")

    return quantity * unit_price


def calculate_discount_amount(base_amount, discount_type, discount_value):
    """Calculate one discount amount in paise."""
    base_amount = max(0, int(base_amount))
    value = Decimal(str(discount_value))

    if discount_type == "fixed":
        amount = money_round(value)
    elif discount_type == "percentage":
        amount = money_round(
            Decimal(base_amount) * value / Decimal("100")
        )
    else:
        raise ValueError("Unsupported discount type.")

    return min(base_amount, max(0, amount))


def allocate_discount(total_discount, line_amounts):
    """
    Distribute a subscription-level discount proportionally.

    The returned amounts always sum to total_discount, provided the
    requested discount does not exceed the sum of line amounts.
    """
    amounts = [max(0, int(value)) for value in line_amounts]
    total_base = sum(amounts)
    discount = min(max(0, int(total_discount)), total_base)

    if not amounts or total_base == 0 or discount == 0:
        return [0 for _ in amounts]

    allocations = []
    remaining = discount

    for index, base in enumerate(amounts):
        if index == len(amounts) - 1:
            allocated = remaining
        else:
            allocated = money_round(
                Decimal(discount) * Decimal(base) /
                Decimal(total_base)
            )
            allocated = min(base, max(0, allocated), remaining)

        allocations.append(allocated)
        remaining -= allocated

    # Correct any rounding remainder without exceeding a line's base.
    if remaining:
        for index in range(len(allocations)):
            capacity = amounts[index] - allocations[index]
            addition = min(capacity, remaining)
            allocations[index] += addition
            remaining -= addition

            if remaining == 0:
                break

    return allocations


def build_invoice_line(
    quantity,
    unit_price,
    discount_amount=0,
    tax_rate=0
):
    """Calculate all monetary values for one invoice line."""
    base = calculate_line_amount(quantity, unit_price)

    discount = min(
        max(0, int(discount_amount)),
        base
    )

    taxable_amount = base - discount
    tax = calculate_tax(taxable_amount, tax_rate)

    return {
        "quantity": int(quantity),
        "unit_price": int(unit_price),
        "base_amount": base,
        "discount_amount": discount,
        "taxable_amount": taxable_amount,
        "tax_rate": float(tax_rate or 0),
        "tax_amount": tax,
        "line_total": taxable_amount + tax,
    }


def calculate_invoice_totals(lines):
    """Calculate invoice subtotal, discount, tax and total."""
    subtotal = sum(line["base_amount"] for line in lines)
    discount_total = sum(
        line["discount_amount"] for line in lines
    )
    tax_total = sum(line["tax_amount"] for line in lines)

    return {
        "subtotal": subtotal,
        "discount_total": discount_total,
        "tax_total": tax_total,
        "total_amount": subtotal - discount_total + tax_total,
    }
