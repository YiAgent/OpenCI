#!/usr/bin/env bats

@test "organization merge policy blocks unsafe states and verifies mutation readback" {
  run node --test "${BATS_TEST_DIRNAME}/merge-organization.test.cjs"
  [ "$status" -eq 0 ]
}
