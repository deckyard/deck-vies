#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# vies overrides the shared example runner.
#
# The examples ask the Commission's VIES service, which is often slow or down
# for a member state, so running them in CI would make the build depend on a
# public service. CI checks that each one still parses against the current
# language and module surface; `jennifer lint` covers them too, in the test
# workflow, and reaches undefined calls. The suite tests every call against a
# loopback fake with VIES's recorded replies.
set -euo pipefail
cd "$(dirname "$0")/.."
exec env EXAMPLES_SKIP_RUN=1 tools/check-examples-shared.sh
