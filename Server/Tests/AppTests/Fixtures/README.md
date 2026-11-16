# Sandbox JWS fixtures

These files hold **real Apple-signed sandbox JWS payloads** — the only
evidence that accepts the positive verifier tests in `JWSVerifierTests`.
They are recorded, never generated: no self-signed or Xcode StoreKit Testing
JWS may be placed here (for `.xcode` / `.localTesting` environments the
library only decodes without chain verification, so such a fixture would
prove nothing and must never be presented as a pass).

## Files

- `sandbox-signed-transaction.txt` — one line: the `jwsRepresentation` of a
  real sandbox purchase of `credits.10` (StoreKit 2 `Transaction.jwsRepresentation`).
- `sandbox-refund-notification.txt` — one line: the `signedPayload` of a real
  sandbox `REFUND` App Store Server Notification (from the sandbox notification
  history in App Store Connect, or from a test notification URL).

## How to record a fixture

1. On the Mac, with the sandbox store signed in, make a real sandbox purchase
   of `credits.10` (requires the product to exist in App Store Connect).
2. Copy the exact `jwsRepresentation` string from the client (or the
   `signedPayload` from App Store Connect's sandbox notification history)
   into the matching file — one line, no quotes, no trailing newline needed.
3. Run `swift test --filter JWSVerifierTests` on the Mac; the positive tests
   must turn green.

## Never commit these files

A JWS is a bearer credential for a real (sandbox) purchase. **Never commit
fixture files to git, and never paste their contents into chat.** They live
only on the Mac that recorded them. If a fixture leaks, treat it like a
leaked token: delete it and re-record.
