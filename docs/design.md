<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Design

## Scope

`@deckyard/vies` validates EU VAT numbers through the European Commission's
VIES service: the check a seller makes before invoicing a business customer
in another member state without VAT (reverse charge). `check` asks
`checkVat`, `checkApprox` asks `checkVatApprox` and returns the consultation
number to keep as proof, and `status` reads VIES's availability per member
state. `normalize`, `parse` and `isWellFormed` work offline.

Not in scope:

- **Check-digit algorithms.** VIES's answer is the authority; the offline
  syntax check only catches obviously wrong input.
- **Caching.** A check is proof only for its date, so every call asks VIES.
- **Trader-detail matching.** `checkApprox` sends the requester only, not the
  optional name, street, postcode and city VIES can match against, and does
  not read the `*Match` fields.
- **Non-EU numbers.** The 27 member states plus `XI` (Northern Ireland).

## Decisions

- **A deck over the bundled `soap` module.** VIES is SOAP 1.1. The deck uses
  `soap.send`, not `soap.call`, so a fault comes back as data and the deck
  maps VIES's `faultstring` codes itself. VIES sends its faults with HTTP 200.
  A faultstring that does not look like a code becomes an error with an
  empty code.
- **Status over REST.** `status` is one `GET` of VIES's REST `check-status`
  over the bundled `http` module. Its URL is not under the SOAP endpoint, so
  it is a separate setting (`withStatusEndpoint`, default `STATUS_ENDPOINT`),
  and `sandboxClient` keeps the live status URL because the test service has
  none.
- **Normalisation.** `normalize` removes spaces, dots and hyphens, upper-cases,
  drops a leading country prefix unless the number already fits its syntax
  (a French key can start with `FR`), maps `GR` to `EL`, and pads a 9-digit
  Belgian number with a leading `0` (VIES asks for and echoes the padded
  form).
- **Syntax before any request.** Each country's pattern is checked offline,
  so an obviously wrong number fails without a request. `sandboxClient`
  turns the per-country check off, because the test service's numbers are
  `100`, `200` and so on. VIES's own limit (2 to 12 of `0-9A-Z+*`) always
  applies.
- **Unknown is not an error.** A number VIES does not know is
  `valid = false`. VIES's `---` for an undisclosed name or address becomes
  `""`; multi-line addresses are kept, with only their ends trimmed. `valid`
  is read as an `xsd:boolean`.
- **Strict replies.** The answer element must be the expected one, and the
  echoed country code and number must equal what was sent. `checkApprox`
  refuses an answer without a `requestIdentifier`: no proof, no result.
  `status` requires the documented JSON shape.
- **Transient faults are retried.** `TRANSIENT_CODES` (a member state or the
  service down, slow or busy) and HTTP 503 (`UNAVAILABLE_STATUS`, VIES's
  maintenance page) are retried `withRetries` times with doubling backoff,
  each wait capped at `MAX_WAIT_MS` (30 s). Other faults and HTTP failures
  are final. `status` is never retried.
- **Naming.** The test-service client is `sandboxClient`, because an
  exported function named `test*` is taken for a test by the runner.

## Errors

- Every error of kind `"vies"` (`ERROR_KIND`) is a `ViesError`: `code` is
  VIES's fault code ("" for an HTTP failure, a malformed reply or an
  unrecognised faultstring), `transient` whether trying later may help,
  `status` the HTTP status of the exchange.
- The generic kinds pass on: `"limit"` for a reply over `MAX_REPLY_BYTES`,
  `"timeout"` and `"closed"` from the transport, `"cancelled"` unchanged,
  and `"net"`: a server that cannot be reached (refused, reset, DNS, TLS, a
  close before any answer) is the transport's `net.NetError`, passed on with
  `reason`, `sent` and `replied` readable. It is never retried, since a
  reset after the request went out may have reached VIES.
- An HTTP failure that `soap` reports in its own kind becomes a `ViesError`
  with code "" and the HTTP status, transient for 503.

## Security and limits

- HTTPS endpoints by default. `withEndpoint` and `withStatusEndpoint` accept
  `http://` only on loopback (for the fake), printable ASCII and no `@`.
- Replies are capped at `MAX_REPLY_BYTES` (64 KiB).
- `withTimeout` sets the idle timeout per request (`DEFAULT_TIMEOUT_MS`,
  30 s); it is not a total deadline. With the 30 s cap per wait, even 10
  retries wait at most about 5 minutes; `withRetries` refuses a first wait
  above the cap.
- No credentials: VIES is public. The requester's own VAT number in
  `checkApprox` is sent as given.

## Testing and validation

- `src/vies_test.j` (30 tests) runs against a loopback `httpd` fake whose
  replies were recorded on 2026-11-14 from the live service and the test
  service (valid and invalid numbers, `checkVatApprox`, faults, the status
  endpoint).
- Checked live against both services on 2026-11-14 (including VIES's 200
  faults, multi-line addresses and Belgian padding).
- The examples ask the live service, so CI only parses them; `examples/check.j`
  without arguments uses the test service.

## Known limitations and open questions

- No check-digit algorithms (optional, later).
- Trader-detail matching in `checkApprox` is not offered.
- `timeoutMs` bounds idle time, not a whole call with its retries.

## Dependencies on the interpreter

- Floor `jennifer >=0.26.0`; the default binary (capability `net`).
- The bundled `soap` module passing `"limit"` on, `"timeout"`, `"closed"`
  and `"cancelled"` since M28.60, and `"net"` (`net.NetError`, M28.65); the
  bundled `http` for `status`.
- Thrown structs classified by kind (`jennifer` `6abf345`, the error-struct
  work of M28.51 to M28.57).
