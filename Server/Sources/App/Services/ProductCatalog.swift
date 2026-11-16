/// Server-side product catalog: product ID → credits granted per purchase.
///
/// Static table in code (not in the database, not from the client). The
/// transaction's `price` is a currency amount and is never used for credits.
///
/// Pending user confirmation (2026-11-16): the products do not exist in App
/// Store Connect yet — the Paid Applications agreement must be accepted first
/// (Account Holder accepts the new Program License Agreement, then the Paid
/// Applications Schedule), and the Calm Frame app record does not exist yet.
/// Prices from that check: credits.10 = ¥6, credits.50 = ¥25. Point values
/// below (10 / 50) follow the feature naming; confirm with the user.
/// If only one product is created, delete the other row here.
enum ProductCatalog {
    static let creditsByProductId: [String: Int] = [
        "credits.10": 10,
        "credits.50": 50,
    ]
}
