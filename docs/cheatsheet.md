<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# vies cheatsheet

Every export of `@deckyard/vies`. Guides are listed in
[the introduction](index.md).

```jennifer
import "@deckyard/vies/" as vies;
```

A refused or failed check throws `ViesError` (kind `"vies"`) with VIES's
fault `code` and `transient`; a reply over its cap is kind `"limit"`.

## Constants

| Constant | Value | Meaning |
|---|---|---|
| `ERROR_KIND` | `"vies"` | the kind of a `ViesError` |
| `ENDPOINT` | `"https://ec.europa.eu/taxation_customs/vies/services/checkVatService"` | the VIES service |
| `TEST_ENDPOINT` | `"https://ec.europa.eu/taxation_customs/vies/services/checkVatTestService"` | the test service |
| `DEFAULT_TIMEOUT_MS` | `30000` | the idle timeout of one request |
| `DEFAULT_RETRIES` | `2` | retries of a transient fault |
| `DEFAULT_BACKOFF_MS` | `1000` | the first wait, doubled after |
| `MAX_WAIT_MS` | `30000` | the longest wait before one retry |
| `UNAVAILABLE_STATUS` | `503` | the HTTP status of the maintenance page, retried like a transient fault |
| `MAX_REPLY_BYTES` | `65536` | the largest reply read |
| `TRANSIENT_CODES` | `["SERVICE_UNAVAILABLE", "MS_UNAVAILABLE", "TIMEOUT", "GLOBAL_MAX_CONCURRENT_REQ", "GLOBAL_MAX_CONCURRENT_REQ_TIME", "MS_MAX_CONCURRENT_REQ", "MS_MAX_CONCURRENT_REQ_TIME"]` | the faults that mean "try again later" |

## Functions

| Function | Returns | Does |
|---|---|---|
| `client()` | `Client` | the VIES service: 30 s, 2 retries, syntax checks on |
| `testClient()` | `Client` | the test service; syntax checks and retries off |
| `withEndpoint(c, url)` | `Client` | another endpoint; `http://` only on this machine |
| `withTimeout(c, ms)` | `Client` | the idle timeout of one request, 1000 to 300000 ms |
| `withRetries(c, n, backoffMs)` | `Client` | retries of a transient fault (0 to 10) and the first wait (0 to `MAX_WAIT_MS`) |
| `check(c, country, number)` | `Result` | check a number; `valid` false when VIES does not know it |
| `checkApprox(c, country, number, requesterCountry, requesterNumber)` | `ApproxResult` | the same with the caller's number; a consultation number as proof |
| `normalize(country, number)` | `VatId` | remove spaces, dots, hyphens and the prefix; `GR` as `EL` |
| `parse(vat)` | `VatId` | a number written with its country prefix |
| `isWellFormed(id)` | `bool` | the number fits its country's syntax |
| `countries()` | `list of string` | the country codes VIES checks |

## Types

### `Client`

| Field | Meaning |
|---|---|
| `endpoint as string` | the SOAP service URL |
| `timeoutMs as int` | the idle timeout of one request |
| `retries as int` | retries of a transient fault |
| `backoffMs as int` | the first wait, doubled after, at most `MAX_WAIT_MS` each |
| `checkSyntax as bool` | refuse a malformed number before sending it |

### `VatId`

| Field | Meaning |
|---|---|
| `country as string` | the VIES country code, such as `DE`, `EL`, `XI` |
| `number as string` | the number without its prefix, upper case |

### `Result`

| Field | Meaning |
|---|---|
| `country as string` | the country code checked |
| `number as string` | the number checked |
| `valid as bool` | registered for intra-EU trade |
| `name as string` | the trader's name, `""` if not disclosed |
| `address as string` | the trader's address, `""` if not disclosed |
| `requestDate as string` | the date of the check, `2026-11-14+01:00` |

### `ApproxResult`

| Field | Meaning |
|---|---|
| `country as string` | the country code checked |
| `number as string` | the number checked |
| `valid as bool` | registered for intra-EU trade |
| `name as string` | the trader's name, `""` if not disclosed |
| `address as string` | the trader's address, `""` if not disclosed |
| `companyType as string` | the company type code, `""` if none |
| `requestDate as string` | the date of the check |
| `requestIdentifier as string` | the consultation number to keep as proof |

### `ViesError`

| Field | Meaning |
|---|---|
| `kind as string` | always `"vies"` |
| `message as string` | `vies: <what>` |
| `code as string` | VIES's fault code, `""` if none |
| `transient as bool` | try again later: a transient fault or a 503 page |
| `status as int` | the HTTP status, 0 for a local error |
