# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

/**
 * White-box tests: jennifer test src/vies_test.j
 *
 * No test needs VIES. A fake on 127.0.0.1 answers each request with a reply
 * recorded from the live service and the Commission's test service on
 * 2026-11-14, and hands back what it received.
 */
use httpd;
use net;
use task;
use testing;

/** A canned reply. */
def struct Reply {
    status as int,
    body as string
};

/** One request as the fake saw it. */
def struct Seen {
    method as string,
    contentType as string,
    action as string,
    body as string
};

/** A running fake. */
def struct Fake {
    srv as httpd.Server,
    url as string,
    t as task of list of Seen
};

def const ENV_OPEN as string init '<env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/"><env:Header/><env:Body>';
def const ENV_CLOSE as string init '</env:Body></env:Envelope>';

# recorded: checkVat IE 6388047V on the live service
def const VALID as string init ENV_OPEN +
    '<ns2:checkVatResponse xmlns:ns2="urn:ec.europa.eu:taxud:vies:services:checkVat:types"><ns2:countryCode>IE</ns2:countryCode><ns2:vatNumber>6388047V</ns2:vatNumber><ns2:requestDate>2026-11-14+01:00</ns2:requestDate><ns2:valid>true</ns2:valid><ns2:name>GOOGLE IRELAND LIMITED</ns2:name><ns2:address>3RD FLOOR, GORDON HOUSE, BARROW STREET, DUBLIN 4</ns2:address></ns2:checkVatResponse>' +
    ENV_CLOSE;

# recorded: checkVat DE 200 on the test service (an invalid number)
def const INVALID as string init ENV_OPEN +
    '<ns2:checkVatResponse xmlns:ns2="urn:ec.europa.eu:taxud:vies:services:checkVat:types"><ns2:countryCode>DE</ns2:countryCode><ns2:vatNumber>200</ns2:vatNumber><ns2:requestDate>2026-11-14+01:00</ns2:requestDate><ns2:valid>false</ns2:valid><ns2:name>---</ns2:name><ns2:address>---</ns2:address></ns2:checkVatResponse>' +
    ENV_CLOSE;

# recorded: checkVatApprox DE 100 by AT 100 on the test service
def const APPROX as string init ENV_OPEN +
    '<ns2:checkVatApproxResponse xmlns:ns2="urn:ec.europa.eu:taxud:vies:services:checkVat:types"><ns2:countryCode>DE</ns2:countryCode><ns2:vatNumber>100</ns2:vatNumber><ns2:requestDate>2026-11-14+01:00</ns2:requestDate><ns2:valid>true</ns2:valid><ns2:traderName>John Doe</ns2:traderName><ns2:traderCompanyType>000</ns2:traderCompanyType><ns2:traderAddress>123 Main St, Anytown, UK</ns2:traderAddress><ns2:traderNameMatch>1</ns2:traderNameMatch><ns2:traderCompanyTypeMatch>1</ns2:traderCompanyTypeMatch><ns2:traderStreetMatch>1</ns2:traderStreetMatch><ns2:traderPostcodeMatch>1</ns2:traderPostcodeMatch><ns2:traderCityMatch>1</ns2:traderCityMatch><ns2:requestIdentifier>WAPI0000001</ns2:requestIdentifier></ns2:checkVatApproxResponse>' +
    ENV_CLOSE;

/**
 * A fault as the test service sends it, with HTTP 200.
 *
 * @param code {string} the faultstring
 * @return {Reply} the reply
 */
func fault(code as string) {
    return Reply{
        status: 200,
        body: ENV_OPEN + '<env:Fault><faultcode>env:Server</faultcode><faultstring>' + $code +
            '</faultstring></env:Fault>' + ENV_CLOSE
    };
}

/**
 * A 200 reply.
 *
 * @param body {string} the envelope
 * @return {Reply} the reply
 */
func ok(body as string) {
    return Reply{status: 200, body: $body};
}

/**
 * Answer one request per reply, in order.
 *
 * @param srv {httpd.Server} the server
 * @param replies {list of Reply} the replies
 * @return {list of Seen} the requests
 */
func serve(srv as httpd.Server, replies as list of Reply) {
    def seen as list of Seen init [];
    for (def r in $replies) {
        def req as httpd.Request init httpd.accept($srv);
        $seen[] = Seen{
            method: httpd.method($req),
            contentType: httpd.header($req, "Content-Type"),
            action: httpd.header($req, "SOAPAction"),
            body: convert.stringFromBytes("utf-8", httpd.body($req))
        };
        httpd.setHeader($req, "Content-Type", "text/xml; charset=utf-8");
        httpd.respond($req, $r.status, $r.body);
    }
    return $seen;
}

/**
 * Start a fake that gives these replies.
 *
 * @param replies {list of Reply} the replies
 * @return {Fake} the fake
 */
func fake(replies as list of Reply) {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def t as task of list of Seen init spawn {
        return serve($srv, $replies);
    };
    return Fake{srv: $srv, url: "http://" + httpd.address($srv) + "/vies", t: $t};
}

/**
 * Stop a fake.
 *
 * @param f {Fake} the fake
 * @return {list of Seen} what it received
 */
func finish(f as Fake) {
    def seen as list of Seen init task.wait($f.t);
    httpd.shutdown($f.srv);
    return $seen;
}

/**
 * A client for a fake: no syntax checks for the test numbers, quick retries.
 *
 * @param f {Fake} the fake
 * @return {Client} the client
 */
func fakeClient(f as Fake) {
    return withRetries(withEndpoint(client(), $f.url), 2, 0);
}

/** Fail a test whose call should have thrown. */
func missed() {
    throw Error{kind: "test", message: "the call did not fail"};
}

func testNormalize() {
    testing.assertEqual(
        normalize("de", "DE 123.456.789"),
        VatId{country: "DE", number: "123456789"});
    testing.assertEqual(normalize("AT", "u-1234 5678"), VatId{country: "AT", number: "U12345678"});
    testing.assertEqual(normalize("GR", "EL 094014201"), VatId{country: "EL", number: "094014201"});
    testing.assertEqual(normalize("gr", "GR094014201"), VatId{country: "EL", number: "094014201"});
    testing.assertEqual(normalize("XI", "XI 123456789"), VatId{country: "XI", number: "123456789"});
    testing.assertEqual(parse("ATU12345678"), VatId{country: "AT", number: "U12345678"});
    testing.assertEqual(parse("nl 8000.36.721.B01"), VatId{country: "NL", number: "800036721B01"});
    for (def bad in [["GB", "123456789"], ["US", "1"], ["", "1"], ["DE", " . - "]]) {
        try {
            normalize($bad[0], $bad[1]);
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
        }
    }
    for (def bad in ["", "12345", "1A"]) {
        try {
            parse($bad);
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
        }
    }
    testing.assertEqual(len(countries()), 28);
    testing.assertTrue(lists.contains(countries(), "XI"));
    testing.assertFalse(lists.contains(countries(), "GR"));
}

func testSyntax() {
    for (def good in [
        "ATU12345678",
        "BE0123456789",
        "BG123456789",
        "BG1234567890",
        "CY12345678X",
        "CZ12345678",
        "CZ1234567890",
        "DE123456789",
        "DK12345678",
        "EE123456789",
        "EL123456789",
        "ESX1234567X",
        "ES12345678Z",
        "FI12345678",
        "FRXX123456789",
        "FR12345678901",
        "HR12345678901",
        "HU12345678",
        "IE6388047V",
        "IE1234567WA",
        "IE1+23456X",
        "IT12345678901",
        "LT123456789",
        "LT123456789012",
        "LU12345678",
        "LV12345678901",
        "MT12345678",
        "NL123456789B01",
        "PL1234567890",
        "PT123456789",
        "RO12",
        "RO1234567890",
        "SE123456789001",
        "SI12345678",
        "SK1234567890",
        "XI123456789",
        "XIGD123",
        "XIHA567"
    ]) {
        testing.assertTrue(isWellFormed(parse($good)));
    }
    for (def bad in [
        "AT12345678",
        "BE2123456789",
        "DE12345678",
        "DE1234567890",
        "NL123456789A01",
        "SE123456789002",
        "RO0123",
        "XIGD523",
        "IE12345678",
        "FR1234567890"
    ]) {
        testing.assertFalse(isWellFormed(parse($bad)));
    }
    testing.assertFalse(isWellFormed(VatId{country: "GB", number: "123456789"}));
}

func testCheck() {
    def f as Fake init fake([ok(VALID), ok(INVALID)]);
    def c as Client init fakeClient($f);
    def r as Result init check($c, "IE", "IE 6388047V");
    testing.assertTrue($r.valid);
    testing.assertEqual($r.country, "IE");
    testing.assertEqual($r.number, "6388047V");
    testing.assertEqual($r.name, "GOOGLE IRELAND LIMITED");
    testing.assertEqual($r.address, "3RD FLOOR, GORDON HOUSE, BARROW STREET, DUBLIN 4");
    testing.assertEqual($r.requestDate, "2026-11-14+01:00");
    # an unknown number is an answer, and VIES's --- is "not disclosed"
    $c.checkSyntax = false;
    def no as Result init check($c, "DE", "200");
    testing.assertFalse($no.valid);
    testing.assertEqual($no.name, "");
    testing.assertEqual($no.address, "");
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "POST");
    testing.assertContains($seen[0].contentType, "text/xml");
    testing.assertEqual($seen[0].action, '""');
    testing.assertContains($seen[0].body, "urn:ec.europa.eu:taxud:vies:services:checkVat:types");
    testing.assertContains($seen[0].body, "checkVat");
    testing.assertContains($seen[0].body, ":countryCode>IE</");
    testing.assertContains($seen[0].body, ":vatNumber>6388047V</");
    testing.assertTrue(
        strings.indexOf($seen[0].body, "countryCode") < strings.indexOf($seen[0].body, "vatNumber"));
}

func testCheckApprox() {
    def f as Fake init fake([ok(APPROX)]);
    def c as Client init fakeClient($f);
    $c.checkSyntax = false;
    def r as ApproxResult init checkApprox($c, "DE", "100", "AT", "100");
    testing.assertTrue($r.valid);
    testing.assertEqual($r.name, "John Doe");
    testing.assertEqual($r.address, "123 Main St, Anytown, UK");
    testing.assertEqual($r.companyType, "000");
    testing.assertEqual($r.requestIdentifier, "WAPI0000001");
    def seen as list of Seen init finish($f);
    def body as string init $seen[0].body;
    testing.assertContains($body, "checkVatApprox");
    testing.assertContains($body, ":requesterCountryCode>AT</");
    testing.assertContains($body, ":requesterVatNumber>100</");
    # the WSDL's sequence order
    testing.assertTrue(strings.indexOf($body, ":vatNumber>") <
        strings.indexOf($body, ":requesterCountryCode>"));
    testing.assertTrue(
        strings.indexOf($body, ":requesterCountryCode>") <
            strings.indexOf($body, ":requesterVatNumber>"));
}

func testSyntaxIsCheckedOffline() {
    # no fake: a request would fail with a connection error, not this one
    def c as Client init withEndpoint(client(), "http://127.0.0.1:9/vies");
    for (def bad in [["DE", "12345"], ["AT", "12345678"], ["FR", "12"], ["DE", "123456789012"]]) {
        try {
            check($c, $bad[0], $bad[1]);
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
            testing.assertEqual($e.code, "");
            testing.assertContains($e.message, "is not a VAT number of");
        }
    }
    try {
        checkApprox($c, "DE", "123456789", "AT", "12345678");
        missed();
    } catch (e) {
        testing.assertContains($e.message, "is not a VAT number of AT");
    }
    # VIES's own limit holds even without syntax checks
    $c.checkSyntax = false;
    try {
        check($c, "DE", "1234567890123");
        missed();
    } catch (e) {
        testing.assertContains($e.message, "2 to 12 of 0-9, A-Z, + and *");
    }
}

func testTransientFaultsAreRetried() {
    def f as Fake init fake([fault("MS_UNAVAILABLE"), fault("MS_MAX_CONCURRENT_REQ"), ok(VALID)]);
    def r as Result init check(fakeClient($f), "IE", "6388047V");
    testing.assertTrue($r.valid);
    testing.assertEqual(len(finish($f)), 3);
}

func testTransientFaultAfterTheRetries() {
    def f as Fake init fake([fault("TIMEOUT"), fault("TIMEOUT"), fault("SERVICE_UNAVAILABLE")]);
    try {
        check(fakeClient($f), "IE", "6388047V");
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertEqual($e.code, "SERVICE_UNAVAILABLE");
        testing.assertTrue($e.transient);
        testing.assertEqual($e.status, 200);
        testing.assertEqual(
            $e.message,
            "vies: checkVat IE6388047V: SERVICE_UNAVAILABLE (after 2 retries)");
    }
    testing.assertEqual(len(finish($f)), 3);
}

func testFinalFaultsAreNotRetried() {
    def f as Fake init fake([
        fault("INVALID_INPUT"),
        fault("INVALID_REQUESTER_INFO"),
        fault("VAT_BLOCKED")
    ]);
    def c as Client init fakeClient($f);
    $c.checkSyntax = false;
    for (def code in ["INVALID_INPUT", "INVALID_REQUESTER_INFO", "VAT_BLOCKED"]) {
        try {
            check($c, "DE", "201");
            missed();
        } catch (e) {
            testing.assertEqual($e.code, $code);
            testing.assertFalse($e.transient);
            testing.assertEqual($e.message, "vies: checkVat DE201: " + $code);
        }
    }
    testing.assertEqual(len(finish($f)), 3);
}

func testRetriesWait() {
    def f as Fake init fake([fault("TIMEOUT"), fault("TIMEOUT"), ok(VALID)]);
    def c as Client init withRetries(withEndpoint(client(), $f.url), 2, 100);
    def started as time.Time init time.now();
    check($c, "IE", "6388047V");
    def took as int init time.milliseconds(time.sub(time.now(), $started));
    # 100 ms, then 200 ms
    testing.assertTrue($took >= 290);
    finish($f);
}

func testOddReplies() {
    def f as Fake init fake([
        Reply{
            status: 200,
            body: ENV_OPEN +
                '<env:Fault><faultcode>env:Server</faultcode><faultstring>something broke: see log</faultstring></env:Fault>' +
                ENV_CLOSE
        },
        ok(strings.replace(VALID, "<ns2:valid>true</ns2:valid>", "<ns2:valid>yes</ns2:valid>")),
        ok(strings.replace(VALID, "<ns2:requestDate>2026-11-14+01:00</ns2:requestDate>", "")),
        ok(ENV_OPEN + ENV_CLOSE),
        Reply{status: 500, body: "<html>broken</html>"}
    ]);
    def c as Client init fakeClient($f);
    for (def want in [
        'fault "something broke: see log"',
        'valid is "yes", not a boolean',
        "the reply has no requestDate",
        "the reply is empty",
        "HTTP 500"
    ]) {
        try {
            check($c, "IE", "6388047V");
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
            testing.assertEqual($e.code, "");
            testing.assertFalse($e.transient);
            testing.assertContains($e.message, $want);
        }
    }
    finish($f);
}

func testAnOversizedReplyIsALimit() {
    def f as Fake init fake([
        ok(strings.replace(VALID, "GOOGLE IRELAND LIMITED", strings.repeat("x", 70000)))
    ]);
    try {
        check(fakeClient($f), "IE", "6388047V");
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, "limit");
    }
    finish($f);
}

# A server that does not answer is kind "timeout", not a ViesError, and is
# not retried (the bundled soap module passes the kind on since 0.26.0).
func testATimeoutIsKindTimeout() {
    def l as net.Listener init net.listen("127.0.0.1:0");
    def t as task of int init spawn {
        def conn as net.Conn init net.accept($l);
        net.readBytes($conn, 65536);
        time.sleep(time.fromMilliseconds(1600));
        net.close($conn);
        return 0;
    };
    def c as Client init withTimeout(
        withRetries(withEndpoint(client(), "http://" + net.address($l) + "/vies"), 2, 0),
        1000);
    try {
        check($c, "IE", "6388047V");
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, "timeout");
        testing.assertContains($e.message, "soap: POST ");
    }
    task.wait($t);
    net.close($l);
}

# Each wait doubles the one before, up to MAX_WAIT_MS: 10 retries wait at
# most 5 minutes in all, not hours.
func testRetryWaitsAreCapped() {
    def c as Client init withRetries(client(), 10, 1000);
    def waits as list of int init [];
    def total as int init 0;
    for (def a in 0..10) {
        $waits[] = retryWait($c, $a);
        $total = $total + retryWait($c, $a);
    }
    testing.assertEqual($waits, [1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000, 30000, 30000]);
    testing.assertEqual($total, 181000);
    def most as Client init withRetries(client(), 10, MAX_WAIT_MS);
    testing.assertEqual(retryWait($most, 0), MAX_WAIT_MS);
    testing.assertEqual(retryWait($most, 9), MAX_WAIT_MS);
    testing.assertEqual(retryWait(withRetries(client(), 2, 0), 1), 0);
}

# The service's 503 maintenance page is retried like a transient fault; any
# other HTTP failure is final.
func testMaintenancePagesAreRetried() {
    def down as Reply init Reply{status: 503, body: "<html>maintenance</html>"};
    def f as Fake init fake([
        $down,
        $down,
        ok(VALID),
        $down,
        $down,
        $down,
        Reply{status: 502, body: "<html>gateway</html>"}
    ]);
    def c as Client init fakeClient($f);
    testing.assertTrue(check($c, "IE", "6388047V").valid);
    try {
        check($c, "IE", "6388047V");
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertEqual($e.code, "");
        testing.assertTrue($e.transient);
        testing.assertEqual($e.status, 503);
        testing.assertContains($e.message, "(after 2 retries)");
    }
    try {
        check($c, "IE", "6388047V");
        missed();
    } catch (e) {
        testing.assertFalse($e.transient);
        testing.assertEqual($e.status, 502);
        testing.assertFalse(strings.contains($e.message, "retries"));
    }
    testing.assertEqual(len(finish($f)), 7);
}

func testClientSettings() {
    def c as Client init client();
    testing.assertEqual($c.endpoint, ENDPOINT);
    testing.assertTrue($c.checkSyntax);
    testing.assertEqual($c.retries, DEFAULT_RETRIES);
    def t as Client init testClient();
    testing.assertEqual($t.endpoint, TEST_ENDPOINT);
    testing.assertFalse($t.checkSyntax);
    testing.assertEqual($t.retries, 0);
    testing.assertEqual(withTimeout($c, 5000).timeoutMs, 5000);
    testing.assertEqual(
        withEndpoint($c, "https://proxy.example.org/vies").endpoint,
        "https://proxy.example.org/vies");
    testing.assertEqual(
        withEndpoint($c, "http://localhost:8080/x").endpoint,
        "http://localhost:8080/x");
    for (def bad in ["http://vies.example.org/", "ftp://x/", "https://x/?a=1", "https://a b/"]) {
        try {
            withEndpoint($c, $bad);
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
        }
    }
    for (def ms in [999, 300001]) {
        try {
            withTimeout($c, $ms);
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
        }
    }
    for (def pair in [[-1, 0], [11, 0], [1, -1], [1, MAX_WAIT_MS + 1]]) {
        try {
            withRetries($c, $pair[0], $pair[1]);
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
        }
    }
}

func testAFrenchKeyFRIsNotAPrefix() {
    # the key of a French number can be the letters FR
    testing.assertEqual(
        normalize("FR", "FR123456789"),
        VatId{country: "FR", number: "FR123456789"});
    testing.assertEqual(
        normalize("fr", "FR FR 123 456 789"),
        VatId{country: "FR", number: "FR123456789"});
    testing.assertEqual(parse("FRFR123456789"), VatId{country: "FR", number: "FR123456789"});
    testing.assertEqual(parse("FR12345678901"), VatId{country: "FR", number: "12345678901"});
    testing.assertTrue(isWellFormed(parse("FRFR123456789")));
}

func testValidIsAnXsdBoolean() {
    def f as Fake init fake([
        ok(strings.replace(VALID, "<ns2:valid>true</ns2:valid>", "<ns2:valid>1</ns2:valid>")),
        ok(strings.replace(INVALID, "<ns2:valid>false</ns2:valid>", "<ns2:valid> 0 </ns2:valid>"))
    ]);
    def c as Client init fakeClient($f);
    $c.checkSyntax = false;
    testing.assertTrue(check($c, "IE", "6388047V").valid);
    testing.assertFalse(check($c, "DE", "200").valid);
    finish($f);
}

func testAnEndpointSoapRefusesIsAViesError() {
    # soap.connect refuses credentials and control characters with kind "soap"
    for (def bad in [
        "https://user:pw@ec.europa.eu/vies",
        "https://ec.europa.eu/vies\u0001",
        "http://127.0.0.1/\u007f"
    ]) {
        try {
            withEndpoint(client(), $bad);
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
        }
    }
}
