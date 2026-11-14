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
    contentType as string,
    body as string
};

/** One request as the fake saw it. */
def struct Seen {
    method as string,
    path as string,
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

def const XML_TYPE as string init "text/xml; charset=utf-8";

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

# recorded: GET check-status on the live service (whitespace removed)
def const STATUS as string init
    '{"vow":{"available":true},"countries":[{"countryCode":"AT","availability":"Available"},{"countryCode":"BE","availability":"Available"},{"countryCode":"BG","availability":"Available"},{"countryCode":"CY","availability":"Available"},{"countryCode":"CZ","availability":"Available"},{"countryCode":"DE","availability":"Available"},{"countryCode":"DK","availability":"Available"},{"countryCode":"EE","availability":"Available"},{"countryCode":"EL","availability":"Available"},{"countryCode":"ES","availability":"Available"},{"countryCode":"FI","availability":"Available"},{"countryCode":"FR","availability":"Available"},{"countryCode":"HR","availability":"Available"},{"countryCode":"HU","availability":"Available"},{"countryCode":"IE","availability":"Available"},{"countryCode":"IT","availability":"Available"},{"countryCode":"LT","availability":"Unavailable"},{"countryCode":"LU","availability":"Available"},{"countryCode":"LV","availability":"Unavailable"},{"countryCode":"MT","availability":"Available"},{"countryCode":"NL","availability":"Available"},{"countryCode":"PL","availability":"Available"},{"countryCode":"PT","availability":"Available"},{"countryCode":"RO","availability":"Available"},{"countryCode":"SE","availability":"Available"},{"countryCode":"SI","availability":"Available"},{"countryCode":"SK","availability":"Available"},{"countryCode":"XI","availability":"Available"}]}';

/**
 * A fault as the test service sends it, with HTTP 200.
 *
 * @param code {string} the faultstring
 * @return {Reply} the reply
 */
func fault(code as string) {
    return Reply{
        status: 200,
        contentType: XML_TYPE,
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
    return Reply{status: 200, contentType: XML_TYPE, body: $body};
}

/**
 * A JSON reply, as the availability endpoint sends it.
 *
 * @param status {int} the HTTP status
 * @param body {string} the document
 * @return {Reply} the reply
 */
func jsonReply(status as int, body as string) {
    return Reply{status: $status, contentType: "application/json", body: $body};
}

/**
 * An HTML page, as the service sends for maintenance or a gateway error.
 *
 * @param status {int} the HTTP status
 * @param body {string} the page
 * @return {Reply} the reply
 */
func page(status as int, body as string) {
    return Reply{status: $status, contentType: "text/html", body: $body};
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
            path: httpd.path($req),
            contentType: httpd.header($req, "Content-Type"),
            action: httpd.header($req, "SOAPAction"),
            body: convert.stringFromBytes("utf-8", httpd.body($req))
        };
        httpd.setHeader($req, "Content-Type", $r.contentType);
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
            contentType: XML_TYPE,
            body: ENV_OPEN +
                '<env:Fault><faultcode>env:Server</faultcode><faultstring>something broke: see log</faultstring></env:Fault>' +
                ENV_CLOSE
        },
        ok(strings.replace(VALID, "<ns2:valid>true</ns2:valid>", "<ns2:valid>yes</ns2:valid>")),
        ok(strings.replace(VALID, "<ns2:requestDate>2026-11-14+01:00</ns2:requestDate>", "")),
        ok(ENV_OPEN + ENV_CLOSE),
        page(500, "<html>broken</html>")
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
            # a refused reply carries its HTTP status
            if ($want == "HTTP 500") {
                testing.assertEqual($e.status, 500);
            } else {
                testing.assertEqual($e.status, 200);
            }
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
    def down as Reply init page(503, "<html>maintenance</html>");
    def f as Fake init fake([
        $down,
        $down,
        ok(VALID),
        $down,
        $down,
        $down,
        page(502, "<html>gateway</html>")
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
    def t as Client init sandboxClient();
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

# A Belgian number of 9 digits is the old form of the 10-digit one: a
# leading 0 makes it whole, and the padded number is what VIES is asked.
func testABelgianNumberOfNineDigitsIsPadded() {
    def want as VatId init VatId{country: "BE", number: "0417497106"};
    testing.assertEqual(normalize("BE", "BE417497106"), $want);
    testing.assertEqual(normalize("be", "417497106"), $want);
    testing.assertEqual(parse("BE417497106"), $want);
    testing.assertEqual(parse("BE 417.497.106"), $want);
    testing.assertEqual(parse("BE0417497106"), $want);
    testing.assertEqual(parse("BE1234567890"), VatId{country: "BE", number: "1234567890"});
    # only Belgium, and only 9 digits
    testing.assertEqual(parse("DE123456789"), VatId{country: "DE", number: "123456789"});
    for (def bad in ["BE41749710", "BE04174971060", "BE2123456789"]) {
        testing.assertFalse(isWellFormed(parse($bad)));
    }
    def reply as string init strings.replace(
        strings.replace(VALID, ">IE<", ">BE<"),
        ">6388047V<",
        ">0417497106<");
    def f as Fake init fake([ok($reply)]);
    def r as Result init check(fakeClient($f), "BE", "417.497.106");
    testing.assertEqual($r.number, "0417497106");
    testing.assertContains(finish($f)[0].body, ":vatNumber>0417497106</");
}

# A checkApprox answer is the proof of the check: without a consultation
# number it is refused, not a result with "".
func testAnApproxAnswerWithoutAnIdentifierIsAnError() {
    def f as Fake init fake([
        ok(regex.replace("<ns2:requestIdentifier>[^<]*</ns2:requestIdentifier>", APPROX, "")),
        ok(strings.replace(APPROX, "WAPI0000001", "")),
        ok(strings.replace(APPROX, "WAPI0000001", "  "))
    ]);
    def c as Client init fakeClient($f);
    $c.checkSyntax = false;
    for (def want in [
        "no requestIdentifier",
        "an empty requestIdentifier",
        "an empty requestIdentifier"
    ]) {
        try {
            checkApprox($c, "DE", "100", "AT", "100");
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
            testing.assertEqual($e.code, "");
            testing.assertFalse($e.transient);
            testing.assertEqual($e.status, 200);
            testing.assertContains($e.message, $want);
        }
    }
    testing.assertEqual(len(finish($f)), 3);
}

# The answer must be the one to the request sent: the operation's response
# element, echoing the number asked.
func testAnAnswerToAnotherRequestIsAnError() {
    def f as Fake init fake([
        ok(strings.replace(INVALID, "checkVatResponse", "checkVatApproxResponse")),
        ok(strings.replace(APPROX, "checkVatApproxResponse", "checkVatResponse")),
        ok(strings.replace(INVALID, "checkVatResponse", "checkVatFault")),
        ok(strings.replace(VALID, ">IE<", ">DE<")),
        ok(strings.replace(VALID, ">6388047V<", ">6388047W<")),
        ok(strings.replace(APPROX, ">DE<", ">AT<")),
        ok(strings.replace(APPROX, ">100<", ">200<"))
    ]);
    def c as Client init fakeClient($f);
    $c.checkSyntax = false;
    def calls as list of list of string init [
        ["check", "DE", "200", 'the reply is "checkVatApproxResponse", not checkVatResponse'],
        ["approx", "DE", "100", 'the reply is "checkVatResponse", not checkVatApproxResponse'],
        ["check", "DE", "200", 'the reply is "checkVatFault", not checkVatResponse'],
        ["check", "IE", "6388047V", 'the reply is for country "DE", not IE'],
        ["check", "IE", "6388047V", 'the reply is for number "6388047W", not 6388047V'],
        ["approx", "DE", "100", 'the reply is for country "AT", not DE'],
        ["approx", "DE", "100", 'the reply is for number "200", not 100']
    ];
    for (def call in $calls) {
        try {
            if ($call[0] == "check") {
                check($c, $call[1], $call[2]);
            } else {
                checkApprox($c, $call[1], $call[2], "AT", "100");
            }
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
            testing.assertEqual($e.code, "");
            testing.assertFalse($e.transient);
            testing.assertEqual($e.status, 200);
            testing.assertContains($e.message, $call[3]);
        }
    }
    testing.assertEqual(len(finish($f)), 7);
}

# The element is matched by its local name: another prefix is the same
# answer.
func testTheReplyPrefixDoesNotMatter() {
    def f as Fake init fake([
        ok(strings.replace(strings.replace(VALID, "ns2:", "v:"), "xmlns:ns2", "xmlns:v"))
    ]);
    def r as Result init check(fakeClient($f), "IE", "6388047V");
    testing.assertTrue($r.valid);
    finish($f);
}

func testStatus() {
    def f as Fake init fake([jsonReply(200, STATUS)]);
    def url as string init strings.replace($f.url, "/vies", "/rest-api/check-status");
    def s as Status init status(withStatusEndpoint(fakeClient($f), $url));
    testing.assertTrue($s.available);
    testing.assertEqual(len($s.countries), 28);
    testing.assertEqual(
        $s.countries[0],
        CountryStatus{country: "AT", availability: "Available", available: true});
    def down as list of string init [];
    for (def cs in $s.countries) {
        if (not $cs.available) {
            $down[] = $cs.country + " " + $cs.availability;
        }
    }
    testing.assertEqual($down, ["LT Unavailable", "LV Unavailable"]);
    def seen as list of Seen init finish($f);
    testing.assertEqual($seen[0].method, "GET");
    testing.assertEqual($seen[0].path, "/rest-api/check-status");
}

# A status VIES does not name "Available" is kept as sent and counts as not
# available; the service's own flag is read as it is.
func testStatusKeepsOtherAvailabilities() {
    def f as Fake init fake([
        jsonReply(
            200,
            '{"vow":{"available":false},"countries":[{"countryCode":"DE","availability":"Monitoring Disabled"}],"extra":1}')
    ]);
    def s as Status init status(withStatusEndpoint(client(), $f.url));
    testing.assertFalse($s.available);
    testing.assertEqual(
        $s.countries,
        [CountryStatus{country: "DE", availability: "Monitoring Disabled", available: false}]);
    finish($f);
}

func testStatusRefusesAMalformedAnswer() {
    def f as Fake init fake([
        page(503, "<html>maintenance</html>"),
        page(500, "<html>broken</html>"),
        page(200, "<html>ok</html>"),
        jsonReply(200, '{"countries":[]}'),
        jsonReply(200, '{"vow":{"available":"yes"},"countries":[]}'),
        jsonReply(200, '{"vow":{"available":true}}'),
        jsonReply(200, '{"vow":{"available":true},"countries":{}}'),
        jsonReply(
            200,
            '{"vow":{"available":true},"countries":[{"countryCode":"de","availability":"Available"}]}'),
        jsonReply(200, '{"vow":{"available":true},"countries":[{"countryCode":"DE"}]}'),
        jsonReply(
            200,
            '{"vow":{"available":true},"countries":[{"countryCode":"DE","availability":""}]}'),
        jsonReply(200, '{"vow":{"available":true},"countries":["DE"]}'),
        jsonReply(200, '[]')
    ]);
    def c as Client init withStatusEndpoint(fakeClient($f), $f.url);
    def wants as list of string init [
        "HTTP 503",
        "HTTP 500",
        "not JSON",
        "no vow/available",
        "no vow/available",
        "no countries",
        "no countries",
        'country code "de"',
        "no availability",
        "no availability",
        "countries/0 is not an object",
        "not an object"
    ];
    for (def i in 0..len($wants)) {
        try {
            status($c);
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
            testing.assertEqual($e.code, "");
            testing.assertContains($e.message, "vies: status: ");
            testing.assertContains($e.message, $wants[$i]);
            # 503 is the maintenance page: try later
            testing.assertEqual($e.transient, $i == 0);
            if ($i == 0) {
                testing.assertEqual($e.status, 503);
            } elseif ($i == 1) {
                testing.assertEqual($e.status, 500);
            } else {
                testing.assertEqual($e.status, 200);
            }
        }
    }
    # not retried: one request each
    testing.assertEqual(len(finish($f)), len($wants));
}

func testAnOversizedStatusIsALimit() {
    def f as Fake init fake([
        jsonReply(200, strings.replace(STATUS, "Unavailable", strings.repeat("x", 70000)))
    ]);
    try {
        status(withStatusEndpoint(client(), $f.url));
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, "limit");
    }
    finish($f);
}

func testAStatusTimeoutIsKindTimeout() {
    def l as net.Listener init net.listen("127.0.0.1:0");
    def t as task of int init spawn {
        def conn as net.Conn init net.accept($l);
        net.readBytes($conn, 65536);
        time.sleep(time.fromMilliseconds(1600));
        net.close($conn);
        return 0;
    };
    def c as Client init withTimeout(
        withStatusEndpoint(client(), "http://" + net.address($l) + "/check-status"),
        1000);
    try {
        status($c);
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, "timeout");
    }
    task.wait($t);
    net.close($l);
}

func testStatusEndpointSettings() {
    testing.assertEqual(client().statusEndpoint, STATUS_ENDPOINT);
    testing.assertEqual(sandboxClient().statusEndpoint, STATUS_ENDPOINT);
    # the SOAP endpoint does not move the status one
    testing.assertEqual(
        withEndpoint(client(), "http://127.0.0.1:8080/vies").statusEndpoint,
        STATUS_ENDPOINT);
    testing.assertEqual(
        withStatusEndpoint(client(), "https://proxy.example.org/status").statusEndpoint,
        "https://proxy.example.org/status");
    testing.assertEqual(
        withStatusEndpoint(client(), "http://[::1]:8080/s").statusEndpoint,
        "http://[::1]:8080/s");
    for (def bad in [
        "http://vies.example.org/",
        "ftp://x/",
        "https://x/?a=1",
        "https://a b/",
        "https://user:pw@ec.europa.eu/s",
        "https://ec.europa.eu/s\u0001"
    ]) {
        try {
            withStatusEndpoint(client(), $bad);
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
        }
    }
}
