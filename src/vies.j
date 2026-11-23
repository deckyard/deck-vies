# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.27.0
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
 * is down or busy, or the service shows its 503 maintenance page: try
 * again later); those are retried with backoff first. A reply over the size cap is kind `"limit"`, a server that
 * does not answer in time `"timeout"`, one that closes the connection
 * mid-reply `"closed"`, and one that cannot be reached (refused, reset, DNS,
 * TLS, a close before any answer) is a `net.NetError` (kind `"net"`), never
 * retried.
 *
 * `status` asks VIES's availability endpoint which member states it can
 * reach now, before a batch of checks or to tell an outage apart.
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
use json;
use lists;
use maps;
use regex;
use strings;
use time;
use xml;

import "http.j" as http;
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

/**
 * VIES's REST availability endpoint, read by `status`. It is not under the
 * SOAP endpoint's path, so `withEndpoint` does not move it; see
 * `withStatusEndpoint`.
 */
export def const STATUS_ENDPOINT as string init "https://ec.europa.eu/taxation_customs/vies/rest-api/check-status";

/** The `availability` VIES gives a member state it can reach. */
export def const AVAILABLE as string init "Available";

/** The XML namespace of the VIES messages. */
def const NS as string init "urn:ec.europa.eu:taxud:vies:services:checkVat:types";

/** The idle timeout of one request unless `withTimeout` says otherwise. */
export def const DEFAULT_TIMEOUT_MS as int init 30000;

/** How often a transient fault is retried unless `withRetries` says otherwise. */
export def const DEFAULT_RETRIES as int init 2;

/** The wait before the first retry, doubled for each further one. */
export def const DEFAULT_BACKOFF_MS as int init 1000;

/**
 * The longest wait before one retry, however often the wait has doubled:
 * with at most 10 retries a check waits at most 5 minutes in all.
 */
export def const MAX_WAIT_MS as int init 30000;

/**
 * The HTTP status of the service's maintenance or overload page, retried
 * like a transient fault.
 */
export def const UNAVAILABLE_STATUS as int init 503;

/**
 * The most bytes a reply may have; VIES replies are well under 4 KiB, the
 * availability status about 2 KiB.
 */
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
 * @field statusEndpoint {string} the availability endpoint `status` reads
 * @field timeoutMs {int} the idle timeout of one request (each read and
 *   write), not a total deadline
 * @field retries {int} how often a transient fault is retried
 * @field backoffMs {int} the wait before the first retry, doubled after, at
 *   most `MAX_WAIT_MS` each
 * @field checkSyntax {bool} refuse a number that does not fit its country's
 *   syntax before sending it; off for the test service, whose numbers are
 *   `100`, `200`, ...
 */
export def struct Client {
    endpoint as string,
    statusEndpoint as string,
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
 *   proof of the check; never `""` (an answer without one is a `ViesError`)
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
 * One member state in the answer to `status`.
 *
 * @field country {string} the VIES country code (`EL` for Greece, `XI`)
 * @field availability {string} VIES's word for it, as sent: `Available`,
 *   `Unavailable`, or any other
 * @field available {bool} `availability` is `AVAILABLE`
 */
export def struct CountryStatus {
    country as string,
    availability as string,
    available as bool
};

/**
 * The answer to `status`.
 *
 * @field available {bool} the VIES service itself is up (the reply's
 *   `vow.available`)
 * @field countries {list of CountryStatus} each member state, in VIES's
 *   order
 */
export def struct Status {
    available as bool,
    countries as list of CountryStatus
};

/**
 * The values of a reply's answer element, and the HTTP status.
 *
 * @field values {map of string to string} the element's children by local name
 * @field status {int} the HTTP status
 */
def struct Answer {
    values as map of string to string,
    status as int
};

/**
 * The error of a check VIES refused or that failed.
 *
 * @field kind {string} always `"vies"`
 * @field message {string} `vies: <what>`
 * @field code {string} VIES's fault code (`INVALID_INPUT`, `MS_UNAVAILABLE`,
 *   ...); `""` for an error found locally or a failed HTTP exchange
 * @field transient {bool} try again later: the fault is one of
 *   `TRANSIENT_CODES`, or the service answered `UNAVAILABLE_STATUS` (503,
 *   its maintenance page)
 * @field status {int} the HTTP status of the reply refused, else 0
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
 * Throw an error about a reply: final, with its HTTP status.
 *
 * @param message {string} what is wrong, without the prefix
 * @param status {int} the HTTP status
 */
func refuse(message as string, status as int) {
    throw ViesError{
        kind: ERROR_KIND,
        message: "vies: " + $message,
        code: "",
        transient: false,
        status: $status
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
        $cut = $cut[..80] + "...";
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
        statusEndpoint: STATUS_ENDPOINT,
        timeoutMs: DEFAULT_TIMEOUT_MS,
        retries: DEFAULT_RETRIES,
        backoffMs: DEFAULT_BACKOFF_MS,
        checkSyntax: true
    };
}

/**
 * A client for the Commission's test service, which answers by number
 * (`100` valid, `200` invalid, `201` and up a fault each). Syntax checks
 * and retries are off. `status` still reads `STATUS_ENDPOINT`: the test
 * service has no availability endpoint.
 *
 * @return {Client} the client
 */
export func sandboxClient() {
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
    $c.endpoint = checkedEndpoint($url);
    return $c;
}

/**
 * Another availability endpoint for `status`: a proxy, or a fake in tests.
 * Plain `http` is allowed only to this machine.
 *
 * @param c {Client} the client
 * @param url {string} the `https://` URL (`http://` on loopback)
 * @return {Client} the changed copy
 * @throws {ViesError} kind `"vies"` for any other URL
 */
export func withStatusEndpoint(c as Client, url as string) {
    $c.statusEndpoint = checkedEndpoint($url);
    return $c;
}

/**
 * An endpoint URL, or an error.
 *
 * @param url {string} the URL
 * @return {string} the URL
 */
func checkedEndpoint(url as string) {
    # printable ASCII without credentials: soap.connect and http refuse the
    # rest with their own kinds
    if (not regex.matches('^[!-~]+$', $url) or
        (not regex.matches('^https://[^/?#@]+(/[^?#]*)?$', $url) and
        not regex.matches('^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?(/[^?#]*)?$', $url))) {
        fail("an endpoint is an https:// URL, or http:// on this machine, got " + shown($url));
    }
    return $url;
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
 * @param backoffMs {int} the wait before the first retry, 0 to
 *   `MAX_WAIT_MS`, doubled for each further one up to `MAX_WAIT_MS`
 * @return {Client} the changed copy
 * @throws {ViesError} kind `"vies"` outside those ranges
 */
export func withRetries(c as Client, n as int, backoffMs as int) {
    if ($n < 0 or $n > 10 or $backoffMs < 0 or $backoffMs > MAX_WAIT_MS) {
        fail("retries are 0 to 10 and a backoff 0 to " + convert.toString(MAX_WAIT_MS) + " ms");
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
 * number whose key is `FR` is not cut. A Belgian number of 9 digits, the
 * old form, gets its leading `0` (`417497106` becomes `0417497106`).
 *
 * @param country {string} the country code, any case (`GR` for Greece is
 *   accepted)
 * @param number {string} the number, with or without its country prefix
 * @return {VatId} the normalised number
 * @throws {ViesError} kind `"vies"` for a country VIES does not cover or an
 *   empty number
 * @example
 *   vies.normalize("de", "DE 123.456.789");   # VatId{country: "DE", number: "123456789"}
 *   vies.normalize("BE", "BE 417.497.106");   # VatId{country: "BE", number: "0417497106"}
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
        $n = $n[2..];
    }
    # Belgian numbers had 9 digits before the leading 0 was added
    if ($cc == "BE" and regex.matches('^[0-9]{9}$', $n)) {
        $n = "0" + $n;
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
    return normalize($t[..2], $t[2..]);
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
 * The note an error carries after retries.
 *
 * @param attempt {int} the retries made
 * @return {string} `" (after N retries)"`, or `""` for none
 */
func retriesNote(attempt as int) {
    if ($attempt == 0) {
        return "";
    }
    return io.sprintf(" (after %d retries)", $attempt);
}

/**
 * The wait before a retry: the backoff doubled once per earlier retry,
 * never more than `MAX_WAIT_MS`.
 *
 * @param c {Client} the client
 * @param attempt {int} the retries made so far, from 0
 * @return {int} milliseconds
 */
func retryWait(c as Client, attempt as int) {
    def wait as int init $c.backoffMs;
    for (def k in 0..$attempt) {
        if ($wait >= MAX_WAIT_MS) {
            return MAX_WAIT_MS;
        }
        $wait = $wait * 2;
    }
    if ($wait > MAX_WAIT_MS) {
        return MAX_WAIT_MS;
    }
    return $wait;
}

/**
 * Send one operation, retrying transient faults, and return the answer
 * element's values.
 *
 * @param c {Client} the client
 * @param op {xml.Value} the operation element
 * @param answer {string} the local name the answer element must have
 * @param what {string} the check, for messages
 * @return {Answer} the answer element's children and the HTTP status
 */
func exchange(c as Client, op as xml.Value, answer as string, what as string) {
    def sc as soap.Client init soap.withMaxBytes(
        soap.withTimeout(soap.connect($c.endpoint), $c.timeoutMs),
        MAX_REPLY_BYTES);
    def attempt as int init 0;
    while (true) {
        def r as soap.Reply;
        def failed as string init "";
        def failedStatus as int init 0;
        try {
            $r = soap.send($sc, "", $op);
        } catch (e) {
            if ($e.kind != soap.ERROR_KIND) {
                throw $e;
            }
            $failed = $e.message;
            $failedStatus = $e.status;
        }
        if ($failed != "") {
            # 503 is the service's maintenance or overload page: a transient
            # failure like MS_UNAVAILABLE, retried the same way
            def busy as bool init $failedStatus == UNAVAILABLE_STATUS;
            if ($busy and $attempt < $c.retries) {
                time.sleep(time.fromMilliseconds(retryWait($c, $attempt)));
                $attempt = $attempt + 1;
                continue;
            }
            throw ViesError{
                kind: ERROR_KIND,
                message: "vies: " + $what + ": " + $failed + retriesNote($attempt),
                code: "",
                transient: $busy,
                status: $failedStatus
            };
        }
        if (not $r.isFault) {
            if (len($r.envelope.body) == 0) {
                refuse($what + ": the reply is empty", $r.status);
            }
            def got as string init xml.localName($r.envelope.body[0]);
            if ($got != $answer) {
                refuse($what + ": the reply is " + shown($got) + ", not " + $answer, $r.status);
            }
            return Answer{values: soap.values($r.envelope.body[0]), status: $r.status};
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
            time.sleep(time.fromMilliseconds(retryWait($c, $attempt)));
            $attempt = $attempt + 1;
        } else {
            throw ViesError{
                kind: ERROR_KIND,
                message: "vies: " + $what + ": " + $code + retriesNote($attempt),
                code: $code,
                transient: $transient,
                status: $r.status
            };
        }
    }
    return Answer{values: {}, status: 0};
}

/**
 * A field VIES must send, or an error.
 *
 * @param a {Answer} the answer
 * @param name {string} the field
 * @param what {string} the check, for messages
 * @return {string} its text
 */
func required(a as Answer, name as string, what as string) {
    if (not maps.has($a.values, $name)) {
        refuse($what + ": the reply has no " + $name, $a.status);
    }
    return $a.values[$name];
}

/**
 * Refuse an answer that does not echo the number asked.
 *
 * @param a {Answer} the answer
 * @param id {VatId} the number sent
 * @param what {string} the check, for messages
 */
func sameNumber(a as Answer, id as VatId, what as string) {
    def cc as string init required($a, "countryCode", $what);
    if ($cc != $id.country) {
        refuse(
            $what + ": the reply is for country " + shown($cc) + ", not " + $id.country,
            $a.status);
    }
    def n as string init required($a, "vatNumber", $what);
    if ($n != $id.number) {
        refuse($what + ": the reply is for number " + shown($n) + ", not " + $id.number, $a.status);
    }
}

/**
 * The `valid` flag of a reply.
 *
 * @param a {Answer} the answer
 * @param what {string} the check, for messages
 * @return {bool} the flag
 */
func validOf(a as Answer, what as string) {
    # xsd:boolean: true, false, 1 or 0, whitespace collapsed
    def t as string init strings.trim(required($a, "valid", $what));
    if ($t == "true" or $t == "1") {
        return true;
    }
    if ($t == "false" or $t == "0") {
        return false;
    }
    refuse($what + ": valid is " + shown($t) + ", not a boolean", $a.status);
    return false;
}

/**
 * An optional text field: `""` when absent or VIES's `---` (not disclosed).
 *
 * @param a {Answer} the answer
 * @param name {string} the field
 * @return {string} the text, trimmed
 */
func optional(a as Answer, name as string) {
    if (not maps.has($a.values, $name)) {
        return "";
    }
    def t as string init strings.trim($a.values[$name]);
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
 *   request) or a fault, with its `code` and `transient`; code `""` for a
 *   reply that is not a `checkVatResponse` for the number sent; `"limit"`
 *   for an oversized reply
 * @throws {net.NetError} kind `"net"` when the service cannot be reached
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
    def a as Answer init exchange($c, $op, "checkVatResponse", $what);
    sameNumber($a, $id, $what);
    return Result{
        country: $id.country,
        number: $id.number,
        valid: validOf($a, $what),
        name: optional($a, "name"),
        address: optional($a, "address"),
        requestDate: required($a, "requestDate", $what)
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
 * @throws {ViesError} kind `"vies"` as `check` (the reply must be a
 *   `checkVatApproxResponse`); `INVALID_REQUESTER_INFO` when VIES refuses the
 *   caller's number; code `""` for an answer without a consultation number
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
    def a as Answer init exchange($c, $op, "checkVatApproxResponse", $what);
    sameNumber($a, $id, $what);
    # the consultation number is the proof the call is made for
    def proof as string init strings.trim(required($a, "requestIdentifier", $what));
    if ($proof == "") {
        refuse($what + ": the reply has an empty requestIdentifier", $a.status);
    }
    return ApproxResult{
        country: $id.country,
        number: $id.number,
        valid: validOf($a, $what),
        name: optional($a, "traderName"),
        address: optional($a, "traderAddress"),
        companyType: optional($a, "traderCompanyType"),
        requestDate: required($a, "requestDate", $what),
        requestIdentifier: $proof
    };
}

/**
 * Ask VIES which member states it can reach now: its REST availability
 * endpoint (`Client.statusEndpoint`), one `GET`, not retried. A member
 * state VIES reports down answers checks with `MS_UNAVAILABLE`.
 *
 * @param c {Client} the client; its `timeoutMs` applies
 * @return {Status} the service's own flag and each member state's
 * @throws {ViesError} kind `"vies"` with code `""` for an HTTP failure (its
 *   `status`; `transient` for `UNAVAILABLE_STATUS`) or a malformed answer;
 *   `"limit"` for a reply over `MAX_REPLY_BYTES`, `"timeout"` when the
 *   server does not answer in time, `"closed"` when it closes the
 *   connection mid-reply
 * @throws {net.NetError} kind `"net"` when the service cannot be reached
 *   (refused, reset, DNS, TLS, a close before any answer)
 * @example
 *   for (def cs in vies.status(vies.client()).countries) {
 *       if (not $cs.available) {
 *           io.printf("%s: %s\n", $cs.country, $cs.availability);
 *       }
 *   }
 */
export func status(c as Client) {
    def what as string init "status";
    def o as http.Options;
    $o.timeoutMs = $c.timeoutMs;
    $o.maxBytes = MAX_REPLY_BYTES;
    def r as http.Response;
    def failed as string init "";
    try {
        $r = http.send("GET", $c.statusEndpoint, {"Accept": "application/json"}, "", $o);
    } catch (e) {
        # generic kinds stay generic: a reached cap, a deadline, a closed
        # connection; a cancelled task and a transport failure (a
        # net.NetError, fields intact) go on as they are
        if ($e.kind == "cancelled" or $e.kind == "net") {
            throw $e;
        }
        if ($e.kind == "limit" or $e.kind == "timeout" or $e.kind == "closed") {
            throw Error{kind: $e.kind, message: "vies: " + $what + ": " + $e.message};
        }
        $failed = $e.message;
    }
    if ($failed != "") {
        refuse($what + ": GET " + shown($c.statusEndpoint) + ": " + shown($failed), 0);
    }
    if ($r.status < 200 or $r.status > 299) {
        throw ViesError{
            kind: ERROR_KIND,
            message: "vies: " + $what + ": HTTP " + convert.toString($r.status),
            code: "",
            transient: $r.status == UNAVAILABLE_STATUS,
            status: $r.status
        };
    }
    def doc as json.Value;
    def bad as bool init false;
    try {
        $doc = json.decode($r.body);
    } catch (e) {
        $bad = true;
    }
    if ($bad) {
        refuse($what + ": the reply is not JSON", $r.status);
    }
    if (json.typeOf($doc, "") != "map") {
        refuse($what + ": the reply is not an object", $r.status);
    }
    if (json.typeOf($doc, "/vow/available") != "bool") {
        refuse($what + ": the reply has no vow/available", $r.status);
    }
    if (json.typeOf($doc, "/countries") != "list") {
        refuse($what + ": the reply has no countries", $r.status);
    }
    def out as list of CountryStatus init [];
    for (def i in 0..json.length($doc, "/countries")) {
        def at as string init "countries/" + convert.toString($i);
        if (json.typeOf($doc, "/" + $at) != "map") {
            refuse($what + ": " + $at + " is not an object", $r.status);
        }
        if (json.typeOf($doc, "/" + $at + "/countryCode") != "string") {
            refuse($what + ": " + $at + " has no countryCode", $r.status);
        }
        def cc as string init json.asString($doc, "/" + $at + "/countryCode");
        if (not regex.matches('^[A-Z]{2}$', $cc)) {
            refuse($what + ": the reply has the country code " + shown($cc), $r.status);
        }
        def word as string init "";
        if (json.typeOf($doc, "/" + $at + "/availability") == "string") {
            $word = json.asString($doc, "/" + $at + "/availability");
        }
        if (strings.trim($word) == "") {
            refuse($what + ": " + $at + " has no availability", $r.status);
        }
        $out[] = CountryStatus{country: $cc, availability: $word, available: $word == AVAILABLE};
    }
    return Status{available: json.asBool($doc, "/vow/available"), countries: $out};
}
