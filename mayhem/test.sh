#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Run the upstream cargo test suite (built by mayhem/build.sh via `cargo test --no-run`).
# Upstream CI runs `cargo test --all-features` with live Postgres/MySQL/MongoDB/MinIO
# containers (docker-compose-dev.yml) plus db client binaries (psql/mysql/mongosh) and a
# docker daemon. None of those exist in the air-gapped commit image, so the tests that
# REQUIRE a live service / docker daemon / db client binary are skipped explicitly below;
# everything else (dump-parser, subset, transformers, config, local_disk, migration, …)
# runs and asserts real behavior.
SKIP_TESTS=(
  # Flaky upstream (time-edge race): 'older_than: 0d' deletes only dumps STRICTLY older
  # than now — when the dump's created_at equals the cutoff second the assert fails ~30%
  # of runs, even with --test-threads=1. Not an environment issue; skipped for determinism.
  datastore::local_disk::tests::test_delete_older_than
  datastore::s3::tests::create_and_get_and_delete_object_for_aws_s3
  datastore::s3::tests::create_and_get_and_delete_object_for_gcp_s3
  datastore::s3::tests::init_s3
  datastore::s3::tests::test_migrate_add_index_file_version_and_rename_backups_to_dumps
  datastore::s3::tests::test_s3_dump_delete_by_name
  datastore::s3::tests::test_s3_dump_delete_older_than
  datastore::s3::tests::test_s3_dump_keep_last
  datastore::s3::tests::test_s3_index_file
  destination::docker::tests::handle_containers
  destination::mongodb::tests::connect
  destination::mongodb_docker::tests::connect
  destination::mysql::tests::connect
  destination::mysql_docker::tests::connect
  destination::postgres::tests::connect
  destination::postgres_docker::tests::connect
  source::mongodb::tests::connect
  source::mongodb::tests::list_rows
  source::mysql::tests::connect
  source::postgres::tests::connect
  source::postgres::tests::subset_options
)
SKIP_ARGS=()
for t in "${SKIP_TESTS[@]}"; do SKIP_ARGS+=(--skip "$t"); done

LOG=/tmp/cargo-test-output.log
# --test-threads=1: local_disk's date-based delete tests are racy under parallelism.
cargo test --workspace --all-features --no-fail-fast -- --test-threads=1 "${SKIP_ARGS[@]}" 2>&1 | tee "$LOG"

# Sum every `test result:` line: "test result: ok. 26 passed; 0 failed; 0 ignored; ..."
read -r PASSED FAILED IGNORED <<< "$(awk '/^test result:/ {
  for (i=1;i<=NF;i++) { if ($(i+1)=="passed;") p+=$i; if ($(i+1)=="failed;") f+=$i; if ($(i+1)=="ignored;") g+=$i }
} END { printf "%d %d %d", p, f, g }' "$LOG")"

SKIPPED=$(( IGNORED + ${#SKIP_TESTS[@]} ))
emit_ctrf "cargo-test" "$PASSED" "$FAILED" "$SKIPPED"
