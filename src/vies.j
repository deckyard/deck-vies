# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * EU VAT number validation through VIES, the European Commission's VAT
 * Information Exchange System: the check a seller makes before invoicing a
 * business customer in another member state without VAT (reverse charge).
 *
 * `check` asks whether a number is registered and returns the trader's name
 * and address where the member state discloses them. `checkApprox` makes the
 * same check with the caller's own VAT number and returns a consultation
 * number, the proof that the check was made on that date. A number is
 * normalised and checked against its country's syntax before any request,
 * so an obviously wrong one fails offline.
 *
 * A number VIES does not know is a result with `valid` false, not an error.
 * A refused or failed check throws `ViesError` (kind `"vies"`) with VIES's
 * fault `code` and whether it is `transient` (a member state or the service
 * is down or busy: try again later); transient faults are retried with
 * backoff first. A reply over the size cap is kind `"limit"`.
 *
 * @module vies
 * @see https://ec.europa.eu/taxation_customs/vies/
 * @example
 *   def r as vies.Result init vies.check(vies.client(), "IE", "6388047V");
 *   if ($r.valid) {
 *       io.printf("%s, %s\n", $r.name, $r.address);
 *   }
 */
use convert;
use io;
use lists;
use maps;
use regex;
use strings;
use time;
use xml;

import "soap.j" as soap;

/** The `kind` of every error the deck throws, except caps and transport kinds. */
export def const ERROR_KIND as string init "vies";

/** The VIES SOAP service. */
export def const ENDPOINT as string init "https://ec.europa.eu/taxation_customs/vies/services/checkVatService";

/**
 * The Commission's test service: fixed answers by number (100 valid, 200
 * invalid, 201 `INVALID_INPUT`, 300 `SERVICE_UNAVAILABLE`, ...).
 */
export def const TEST_ENDPOINT as string init "https://ec.europa.eu/taxation_customs/vies/services/checkVatTestService";

/** The XML namespace of the VIES messages. */
def const NS as string init "urn:ec.europa.eu:taxud:vies:services:checkVat:types";

/** The idle timeout of one request unless `withTimeout` says otherwise. */
export def const DEFAULT_TIMEOUT_MS as int init 30000;

/** How often a transient fault is retried unless `withRetries` says otherwise. */
export def const DEFAULT_RETRIES as int init 2;

/** The wait before the first retry, doubled for each further one. */
export def const DEFAULT_BACKOFF_MS as int init 1000;

/** The most bytes a reply may have; VIES replies are well under 4 KiB. */
export def const MAX_REPLY_BYTES as int init 65536;

/**
 * The faults that mean "try again later": a member state or the service is
 * down, slow or busy. Any other fault is final.
 */
export def const TRANSIENT_CODES as list of string init [
    "SERVICE_UNAVAILABLE",
    "MS_UNAVAILABLE",
    "TIMEOUT",
    "GLOBAL_MAX_CONCURRENT_REQ",
    "GLOBAL_MAX_CONCURRENT_REQ_TIME",
    "MS_MAX_CONCURRENT_REQ",
    "MS_MAX_CONCURRENT_REQ_TIME"
];

/**
 * The syntax of each country's VAT number after normalisation, without the
 * country prefix: the 27 member states as VIES codes them (`EL` for
 * Greece) and `XI` for Northern Ireland.
 */
def const SYNTAX as map of string to string init {
    "AT": 'U[0-9]{8}',
    "BE": '[01][0-9]{9}',
    "BG": '[0-9]{9,10}',
    "CY": '[0-9]{8}[A-Z]',
    "CZ": '[0-9]{8,10}',
    "DE": '[0-9]{9}',
    "DK": '[0-9]{8}',
    "EE": '[0-9]{9}',
    "EL": '[0-9]{9}',
    "ES": '[0-9A-Z][0-9]{7}[0-9A-Z]',
    "FI": '[0-9]{8}',
    "FR": '[0-9A-Z]{2}[0-9]{9}',
    "HR": '[0-9]{11}',
    "HU": '[0-9]{8}',
    "IE": '[0-9][0-9A-Z+*][0-9]{5}[A-Z]{1,2}',
    "IT": '[0-9]{11}',
    "LT": '[0-9]{9}|[0-9]{12}',
    "LU": '[0-9]{8}',
    "LV": '[0-9]{11}',
    "MT": '[0-9]{8}',
    "NL": '[0-9]{9}B[0-9]{2}',
    "PL": '[0-9]{10}',
    "PT": '[0-9]{9}',
    "RO": '[1-9][0-9]{1,9}',
    "SE": '[0-9]{10}01',
    "SI": '[0-9]{8}',
    "SK": '[0-9]{10}',
    "XI": '[0-9]{9}|[0-9]{12}|GD[0-4][0-9]{2}|HA[5-9][0-9]{2}'
};

/**
 * A VIES client.
 *
 * @field endpoint {string} the SOAP service URL
 * @field timeoutMs {int} the idle timeout of one request (each read and
 *   write), not a total deadline
 * @field retries {int} how often a transient fault is retried
 * @field backoffMs {int} the wait before the first retry, doubled after
 * @field checkSyntax {bool} refuse a number that does not fit its country's
 *   syntax before sending it; off for the test service, whose numbers are
 *   `100`, `200`, ...
 */
export def struct Client {
    endpoint as string,
    timeoutMs as int,
    retries as int,
    backoffMs as int,
    checkSyntax as bool
};

/**
 * A normalised VAT number.
 *
 * @field country {string} the VIES country code, such as `DE`, `EL` or `XI`
 * @field number {string} the number without the country prefix, upper case
 */
export def struct VatId {
    country as string,
    number as string
};

/**
 * The answer to `check`.
 *
 * @field country {string} the country code checked
 * @field number {string} the number checked
 * @field valid {bool} the number is registered for intra-EU trade
 * @field name {string} the trader's name; `""` when the member state does
 *   not disclose it (VIES's `---`)
 * @field address {string} the trader's address; `""` when not disclosed
 * @field requestDate {string} the date of the check, as VIES writes it
 *   (`2026-11-14+01:00`)
 */
export def struct Result {
    country as string,
    number as string,
    valid as bool,
    name as string,
    address as string,
    requestDate as string
};

/**
 * The answer to `checkApprox`.
 *
 * @field country {string} the country code checked
 * @field number {string} the number checked
 * @field valid {bool} the number is registered for intra-EU trade
 * @field name {string} the trader's name; `""` when not disclosed
 * @field address {string} the trader's address; `""` when not disclosed
 * @field companyType {string} the trader's company type code where the
 *   member state gives one, else `""`
 * @field requestDate {string} the date of the check, as VIES writes it
 * @field requestIdentifier {string} the consultation number: keep it as
 *   proof of the check; `""` when VIES gave none
 */
export def struct ApproxResult {
    country as string,
    number as string,
    valid as bool,
    name as string,
    address as string,
    companyType as string,
    requestDate as string,
    requestIdentifier as string
};

/**
 * The error of a check VIES refused or that failed.
 *
 * @field kind {string} always `"vies"`
 * @field message {string} `vies: <what>`
 * @field code {string} VIES's fault code (`INVALID_INPUT`, `MS_UNAVAILABLE`,
 *   ...); `""` for an error found locally or a transport failure
 * @field transient {bool} the fault is one of `TRANSIENT_CODES`: try again
 *   later
 * @field status {int} the HTTP status of a failed exchange, else 0
 */
export def struct ViesError {
    kind as string,
    message as string,
    code as string,
    transient as bool,
    status as int
};

/**
 * Throw a local error.
 *
 * @param message {string} what is wrong, without the prefix
 */
func fail(message as string) {
    throw ViesError{
        kind: ERROR_KIND,
        message: "vies: " + $message,
        code: "",
        transient: false,
        status: 0
    };
}

/**
 * A string fit for an error message: printable ASCII only, cut to 80
 * characters.
 *
 * @param text {string} the text
 * @return {string} the text, quoted
 */
func shown(text as string) {
    def cut as string init $text;
    if (len($cut) > 80) {
        $cut = strings.substring($cut, 0, 80) + "...";
    }
    return "\"" + regex.replace("[^ -~]", $cut, "?") + "\"";
}

/**
 * A client for the VIES service: 30 s idle timeout, two retries of a
 * transient fault, syntax checks on.
 *
 * @return {Client} the client
 */
export func client() {
    return Client{
        endpoint: ENDPOINT,
        timeoutMs: DEFAULT_TIMEOUT_MS,
        retries: DEFAULT_RETRIES,
        backoffMs: DEFAULT_BACKOFF_MS,
        checkSyntax: true
    };
}

/**
 * A client for the Commission's test service, which answers by number
 * (`100` valid, `200` invalid, `201` and up a fault each). Syntax checks
 * and retries are off.
 *
 * @return {Client} the client
 */
export func testClient() {
    def c as Client init client();
    $c.endpoint = TEST_ENDPOINT;
    $c.retries = 0;
    $c.checkSyntax = false;
    return $c;
}

/**
 * Another endpoint: a proxy, or a fake in tests. Plain `http` is allowed
 * only to this machine.
 *
 * @param c {Client} the client
 * @param url {string} the `https://` URL (`http://` on loopback)
 * @return {Client} the changed copy
 * @throws {ViesError} kind `"vies"` for any other URL
 */
export func withEndpoint(c as Client, url as string) {
    # printable ASCII without credentials: soap.connect refuses the rest
    # with its own kind
    if (not regex.matches('^[!-~]+$', $url) or
        (not regex.matches('^https://[^/?#@]+(/[^?#]*)?$', $url) and
        not regex.matches('^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?(/[^?#]*)?$', $url))) {
        fail("an endpoint is an https:// URL, or http:// on this machine, got " + shown($url));
    }
    $c.endpoint = $url;
    return $c;
}

/**
 * The idle timeout of one request: how long each read or write may wait,
 * not a deadline for the whole exchange.
 *
 * @param c {Client} the client
 * @param ms {int} milliseconds, 1000 to 300000
 * @return {Client} the changed copy
 * @throws {ViesError} kind `"vies"` outside that range
 */
export func withTimeout(c as Client, ms as int) {
    if ($ms < 1000 or $ms > 300000) {
        fail("a timeout is 1000 to 300000 ms, got " + convert.toString($ms));
    }
    $c.timeoutMs = $ms;
    return $c;
}

/**
 * How often a transient fault is retried, and the first wait.
 *
 * @param c {Client} the client
 * @param n {int} retries, 0 to 10
 * @param backoffMs {int} the wait before the first retry, 0 to 60000 ms,
 *   doubled for each further one
 * @return {Client} the changed copy
 * @throws {ViesError} kind `"vies"` outside those ranges
 */
export func withRetries(c as Client, n as int, backoffMs as int) {
    if ($n < 0 or $n > 10 or $backoffMs < 0 or $backoffMs > 60000) {
        fail("retries are 0 to 10 and a backoff 0 to 60000 ms");
    }
    $c.retries = $n;
    $c.backoffMs = $backoffMs;
    return $c;
}

/**
 * The country codes VIES checks: the 27 member states (`EL` for Greece)
 * and `XI` for Northern Ireland.
 *
 * @return {list of string} the codes, sorted
 */
export func countries() {
    return lists.sort(maps.keys(SYNTAX));
}

/**
 * Normalise a VAT number: spaces, dots and hyphens removed, upper case, a
 * leading country prefix removed, `GR` taken as `EL`. A number that already
 * fits its country's syntax keeps its first two characters, so a French
 * number whose key is `FR` is not cut.
 *
 * @param country {string} the country code, any case (`GR` for Greece is
 *   accepted)
 * @param number {string} the number, with or without its country prefix
 * @return {VatId} the normalised number
 * @throws {ViesError} kind `"vies"` for a country VIES does not cover or an
 *   empty number
 * @example
 *   vies.normalize("de", "DE 123.456.789");   # VatId{country: "DE", number: "123456789"}
 */
export func normalize(country as string, number as string) {
    def cc as string init strings.upper(strings.trim($country));
    if ($cc == "GR") {
        $cc = "EL";
    }
    if (not maps.has(SYNTAX, $cc)) {
        fail("VIES does not check the country " + shown($country));
    }
    def n as string init strings.upper(regex.replace('[\s.\-]', $number, ""));
    # A number that fits its syntax as written keeps its first two
    # characters: a French key can be the letters FR.
    def fits as bool init regex.matches("^(?:" + SYNTAX[$cc] + ")$", $n);
    if (not $fits and
        (strings.startsWith($n, $cc) or ($cc == "EL" and strings.startsWith($n, "GR")))) {
        $n = strings.substring($n, 2);
    }
    if ($n == "") {
        fail("a VAT number is not empty");
    }
    return VatId{country: $cc, number: $n};
}

/**
 * Split a VAT number written with its country prefix, such as
 * `ATU12345678` or `DE 123 456 789`, and normalise it.
 *
 * @param vat {string} the number with its two-letter prefix
 * @return {VatId} the normalised number
 * @throws {ViesError} kind `"vies"` as `normalize`, or without a prefix
 */
export func parse(vat as string) {
    def t as string init regex.replace('[\s.\-]', $vat, "");
    if (len($t) < 3 or not regex.matches('^[A-Za-z]{2}', $t)) {
        fail("a VAT number starts with its country code, got " + shown($vat));
    }
    return normalize(strings.substring($t, 0, 2), strings.substring($t, 2));
}

/**
 * Whether a normalised number fits its country's syntax. It says nothing
 * about the number being registered: only VIES knows that.
 *
 * @param id {VatId} the number, from `normalize` or `parse`
 * @return {bool} true when the syntax fits
 */
export func isWellFormed(id as VatId) {
    if (not maps.has(SYNTAX, $id.country)) {
        return false;
    }
    return regex.matches("^(?:" + SYNTAX[$id.country] + ")$", $id.number);
}

/**
 * Normalise a number and, with syntax checks on, refuse one that does not
 * fit; VIES's own limit (2 to 12 of `0-9 A-Z + *`) holds in every case.
 *
 * @param c {Client} the client
 * @param country {string} the country code
 * @param number {string} the number
 * @return {VatId} the normalised number
 */
func ready(c as Client, country as string, number as string) {
    def id as VatId init normalize($country, $number);
    if (not regex.matches('^[0-9A-Z+*]{2,12}$', $id.number)) {
        fail("a VAT number is 2 to 12 of 0-9, A-Z, + and *, got " + shown($number));
    }
    if ($c.checkSyntax and not isWellFormed($id)) {
        fail(io.sprintf("%s is not a VAT number of %s", shown($number), $id.country));
    }
    return $id;
}

/**
 * Send one operation, retrying transient faults, and return the result
 * element's values.
 *
 * @param c {Client} the client
 * @param op {xml.Value} the operation element
 * @param what {string} the check, for messages
 * @return {map of string to string} the result element's children
 */
func exchange(c as Client, op as xml.Value, what as string) {
    def sc as soap.Client init soap.withMaxBytes(
        soap.withTimeout(soap.connect($c.endpoint), $c.timeoutMs),
        MAX_REPLY_BYTES);
    def attempt as int init 0;
    while (true) {
        def r as soap.Reply;
        try {
            $r = soap.send($sc, "", $op);
        } catch (e) {
            if ($e.kind != soap.ERROR_KIND) {
                throw $e;
            }
            throw ViesError{
                kind: ERROR_KIND,
                message: "vies: " + $what + ": " + $e.message,
                code: "",
                transient: false,
                status: $e.status
            };
        }
        if (not $r.isFault) {
            if (len($r.envelope.body) == 0) {
                fail($what + ": the reply is empty");
            }
            return soap.values($r.envelope.body[0]);
        }
        def code as string init strings.trim($r.fault.reason);
        if (not regex.matches('^[A-Z][A-Z_]{0,63}$', $code)) {
            throw ViesError{
                kind: ERROR_KIND,
                message: "vies: " + $what + ": fault " + shown($r.fault.reason),
                code: "",
                transient: false,
                status: $r.status
            };
        }
        def transient as bool init lists.contains(TRANSIENT_CODES, $code);
        if ($transient and $attempt < $c.retries) {
            def wait as int init $c.backoffMs;
            for (def k in 0..$attempt) {
                $wait = $wait * 2;
            }
            time.sleep(time.fromMilliseconds($wait));
            $attempt = $attempt + 1;
        } else {
            def tries as string init "";
            if ($attempt > 0) {
                $tries = io.sprintf(" (after %d retries)", $attempt);
            }
            throw ViesError{
                kind: ERROR_KIND,
                message: "vies: " + $what + ": " + $code + $tries,
                code: $code,
                transient: $transient,
                status: $r.status
            };
        }
    }
    return {};
}

/**
 * A field VIES must send, or an error.
 *
 * @param v {map of string to string} the result's values
 * @param name {string} the field
 * @param what {string} the check, for messages
 * @return {string} its text
 */
func required(v as map of string to string, name as string, what as string) {
    if (not maps.has($v, $name)) {
        fail($what + ": the reply has no " + $name);
    }
    return $v[$name];
}

/**
 * The `valid` flag of a reply.
 *
 * @param v {map of string to string} the result's values
 * @param what {string} the check, for messages
 * @return {bool} the flag
 */
func validOf(v as map of string to string, what as string) {
    # xsd:boolean: true, false, 1 or 0, whitespace collapsed
    def t as string init strings.trim(required($v, "valid", $what));
    if ($t == "true" or $t == "1") {
        return true;
    }
    if ($t == "false" or $t == "0") {
        return false;
    }
    fail($what + ": valid is " + shown($t) + ", not a boolean");
    return false;
}

/**
 * An optional text field: `""` when absent or VIES's `---` (not disclosed).
 *
 * @param v {map of string to string} the result's values
 * @param name {string} the field
 * @return {string} the text, trimmed
 */
func optional(v as map of string to string, name as string) {
    if (not maps.has($v, $name)) {
        return "";
    }
    def t as string init strings.trim($v[$name]);
    if ($t == "---") {
        return "";
    }
    return $t;
}

/**
 * Check a VAT number.
 *
 * @param c {Client} the client
 * @param country {string} the country code (`GR` is taken as `EL`)
 * @param number {string} the number, with or without its country prefix
 * @return {Result} the answer; `valid` false for a number VIES does not
 *   know
 * @throws {ViesError} kind `"vies"` for a malformed number (before any
 *   request) or a fault, with its `code` and `transient`; `"limit"` for an
 *   oversized reply
 * @example
 *   def r as vies.Result init vies.check(vies.client(), "AT", "U12345678");
 */
export func check(c as Client, country as string, number as string) {
    def id as VatId init ready($c, $country, $number);
    def what as string init "checkVat " + $id.country + $id.number;
    def op as xml.Value init soap.operation(
        NS,
        "checkVat",
        {"countryCode": $id.country, "vatNumber": $id.number},
        true);
    def v as map of string to string init exchange($c, $op, $what);
    return Result{
        country: required($v, "countryCode", $what),
        number: required($v, "vatNumber", $what),
        valid: validOf($v, $what),
        name: optional($v, "name"),
        address: optional($v, "address"),
        requestDate: required($v, "requestDate", $what)
    };
}

/**
 * Check a VAT number with the caller's own, and get a consultation number,
 * the proof that the check was made.
 *
 * @param c {Client} the client
 * @param country {string} the country code of the number checked
 * @param number {string} the number checked
 * @param requesterCountry {string} the caller's own country code
 * @param requesterNumber {string} the caller's own VAT number
 * @return {ApproxResult} the answer with its `requestIdentifier`
 * @throws {ViesError} kind `"vies"` as `check`; `INVALID_REQUESTER_INFO`
 *   when VIES refuses the caller's number
 */
export func checkApprox(
    c as Client,
    country as string,
    number as string,
    requesterCountry as string,
    requesterNumber as string) {
    def id as VatId init ready($c, $country, $number);
    def me as VatId init ready($c, $requesterCountry, $requesterNumber);
    def what as string init "checkVatApprox " + $id.country + $id.number;
    def op as xml.Value init soap.operation(
        NS,
        "checkVatApprox",
        {
            "countryCode": $id.country,
            "vatNumber": $id.number,
            "requesterCountryCode": $me.country,
            "requesterVatNumber": $me.number
        },
        true);
    def v as map of string to string init exchange($c, $op, $what);
    return ApproxResult{
        country: required($v, "countryCode", $what),
        number: required($v, "vatNumber", $what),
        valid: validOf($v, $what),
        name: optional($v, "traderName"),
        address: optional($v, "traderAddress"),
        companyType: optional($v, "traderCompanyType"),
        requestDate: required($v, "requestDate", $what),
        requestIdentifier: optional($v, "requestIdentifier")
    };
}
