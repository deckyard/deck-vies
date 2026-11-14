<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# @deckyard/vies

EU VAT number validation through VIES, the European Commission's VAT
Information Exchange System: the check a seller makes before invoicing a
business customer in another member state without VAT (reverse charge).
VIES asks the member state's own register, so its answer is the authority.

## Conventions

Snippets assume this import:

```jennifer
import "@deckyard/vies/" as vies;
```

## Checking a number

```jennifer
def r as vies.Result init vies.check(vies.client(), "IE", "IE 6388047V");
if ($r.valid) {
    io.printf("%s, %s (%s)\n", $r.name, $r.address, $r.requestDate);
}
```

A number VIES does not know is an answer with `valid` false, not an
error. Some member states do not disclose the trader's name or address;
VIES then sends `---`, which the deck turns into `""`. An address often
spans several lines (`"OOSTERDOKSKADE 00163\n1011DL AMSTERDAM"`); the deck
trims its ends only.

`checkApprox` makes the same check and also sends the caller's own VAT
number. Its answer carries a consultation number, `requestIdentifier`:
keep it with the invoice as proof that the number was checked on that
date. A check is proof only for its date, so the deck caches nothing.

```jennifer
def p as vies.ApproxResult init vies.checkApprox(vies.client(), "DE", "123456789", "AT", "U12345678");
io.printf("%s %s\n", $p.requestDate, $p.requestIdentifier);
```

## Normalising

`normalize(country, number)` removes spaces, dots and hyphens, upper-cases
the number and drops a leading country prefix; `parse(vat)` splits a
number written with its prefix (`"ATU12345678"`, `"de 123 456 789"`).
VIES's country codes are the member states' ISO codes, except `EL` for
Greece (`GR` is accepted and taken as `EL`), plus `XI` for Northern
Ireland; `countries()` lists them. A number that already fits its country's
syntax keeps its first two characters, so a French number whose key is
`FR` (`"FR123456789"`) is not taken for a prefix.

Before any request, `check` refuses a number that does not fit its
country's syntax (`isWellFormed`), so an obviously wrong number fails
offline. The syntax says nothing about a number being registered; check
digits are left to VIES.

## Errors and retries

A refused or failed check throws `ViesError` (kind `"vies"`):

| Field | Meaning |
|---|---|
| `code` | VIES's fault code, `""` for an error found locally or a transport failure |
| `transient` | the fault means "try again later" (`TRANSIENT_CODES`) |
| `status` | the HTTP status of the exchange, 0 for a local error |

A transport failure, a timeout included, is a `ViesError` with code `""`
and is not retried: the bundled `soap` module passes only `"limit"` on.

The fault codes:

| Code | Meaning | Transient |
|---|---|---|
| `INVALID_INPUT` | the country code is unknown or the number empty | no |
| `INVALID_REQUESTER_INFO` | VIES refused the requester's number (`checkApprox`) | no |
| `VAT_BLOCKED`, `IP_BLOCKED` | the number or the caller is blocked | no |
| `SERVICE_UNAVAILABLE` | VIES itself failed | yes |
| `MS_UNAVAILABLE` | the member state's register does not answer | yes |
| `TIMEOUT` | the member state did not answer in time | yes |
| `GLOBAL_MAX_CONCURRENT_REQ`, `MS_MAX_CONCURRENT_REQ` (and `_TIME`) | too many requests, overall or to that member state | yes |

A transient fault is retried `DEFAULT_RETRIES` (2) times, waiting 1 s and
then 2 s; `withRetries(c, n, backoffMs)` changes both. A member state is
often down for maintenance at night: a transient error after the retries
means "check again later", not "the number is wrong". A reply over 64 KiB
is kind `"limit"`.

```jennifer
try {
    def r as vies.Result init vies.check(vies.client(), "FR", "12345678901");
} catch (e) {
    if ($e.kind == vies.ERROR_KIND and $e.transient) {
        io.printf("VIES is busy, try later: %s\n", $e.code);
    }
}
```

## The test service

`testClient()` talks to the Commission's test service, which answers by
number: `100` is valid, `200` invalid, and `201` to `601` each return
one fault (`300` `SERVICE_UNAVAILABLE`, `600` `MS_MAX_CONCURRENT_REQ`,
...). Syntax checks and retries are off on it.
