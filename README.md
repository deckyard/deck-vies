# @deckyard/vies

[![test](https://github.com/deckyard/deck-vies/actions/workflows/test.yml/badge.svg)](https://github.com/deckyard/deck-vies/actions/workflows/test.yml)
[![Documentation](https://img.shields.io/badge/docs-github%20pages-blue)](https://deckyard.github.io/deck-vies/)
[![release](https://img.shields.io/github/v/release/deckyard/deck-vies)](https://github.com/deckyard/deck-vies/releases/latest)

EU VAT number validation through VIES, the European Commission's VAT
Information Exchange System, for [Jennifer](https://jennifer-lang.dev/)
programs: check a customer's VAT number before invoicing without VAT
(reverse charge), with the trader's name and address, and get a
consultation number as proof of the check. Numbers are normalised and
checked against their country's syntax offline; VIES's faults keep "the
member state is down, try later" apart from "the number is wrong".

**[Documentation](https://deckyard.github.io/deck-vies/)**

## Install

```sh
jvc add @deckyard/vies
```

This vendors the deck to `vendor/<scope>/vies/`. Without `jvc`, unpack the
`src/` subtree of a release archive (`<scope>-vies-<version>.tar.gz`) there.

## Usage

```jennifer
import "@deckyard/vies/" as vies;

def r as vies.Result init vies.check(vies.client(), "IE", "IE 6388047V");
io.printf("%s %s\n", $r.valid, $r.name);
```

`examples/check.j` checks the numbers given as arguments, or asks the
Commission's test service without them.

## Requirements

Jennifer 0.26.0 or newer, with the `net` capability: the checks are SOAP
requests to the Commission's VIES service, over the bundled `soap` module.

## Development

```sh
tools/check-all.sh                 # the full gate, as CI runs it
jennifer test src/vies_test.j      # the test overlay
tools/check-docs.sh                # docs against the code
tools/pack.sh dist                 # build the release archive
```

## Licence

LGPL-3.0-only, see [LICENSE](LICENSE). Copyright (C) 2026 mplx &lt;mplx@jennifer-lang.dev&gt;.

`tools/check-headers.sh` checks every source file's SPDX header against
`deck.toml`.
