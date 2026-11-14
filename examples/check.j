#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * Check VAT numbers: jennifer run examples/check.j ATU12345678 "DE 123 456 789"
 *
 * Each argument is a number with its country prefix. Without arguments it
 * asks the Commission's test service for its fixed numbers instead.
 * Exits 1 when a number is not valid, 2 when a check failed.
 */
use io;
use os;

import "../src/vies.j" as vies;

# os.ARGS[0] is the script itself
def args as list of string init os.ARGS[1..len(os.ARGS)];
def c as vies.Client init vies.client();
def numbers as list of vies.VatId init [];
if (len($args) == 0) {
    $c = vies.testClient();
    $numbers = [vies.normalize("DE", "100"), vies.normalize("DE", "200")];
} else {
    for (def a in $args) {
        $numbers[] = vies.parse($a);
    }
}
def status as int init 0;
for (def id in $numbers) {
    try {
        def r as vies.Result init vies.check($c, $id.country, $id.number);
        if ($r.valid) {
            io.printf("%s%s valid  %s, %s\n", $id.country, $id.number, $r.name, $r.address);
        } else {
            io.printf("%s%s NOT valid\n", $id.country, $id.number);
            if ($status == 0) {
                $status = 1;
            }
        }
    } catch (e) {
        io.printf("%s%s check failed: %s\n", $id.country, $id.number, $e.message);
        $status = 2;
    }
}
exit ($status);
