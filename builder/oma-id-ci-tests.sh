#!/bin/bash
# In-container CI tests for the OMA-ID stand-in layer (packaging-smoke job).
# Run AFTER the layer is installed with AIROOTFS=/ so artifacts sit at their
# real ISO paths. Exit nonzero on any failure.
set -euo pipefail

echo '=== smoke matrix under bash ==='
bash /opt/oma-id/run-smoke.sh

echo '=== smoke matrix under zsh (live-root shell) ==='
zsh /opt/oma-id/run-smoke.sh

echo '=== installer-choice: valid metadata (stub server) ==='
stub_dir=$(mktemp -d)
mkdir -p "$stub_dir/.well-known" "$stub_dir/bad/.well-known"
cat > "$stub_dir/.well-known/oma-enrollment" <<'JSON'
{"protocol":{"name":"oma-enrollment","versions":["0"]},"issuer":"http://stub.test:3000","organization":{"name":"CI Stub Org","support_email":"admin@stub.test"},"enrollment_methods":[]}
JSON
cat > "$stub_dir/bad/.well-known/oma-enrollment" <<'JSON'
{"protocol":{"name":"someone-elses-protocol","versions":["0"]},"issuer":"http://stub.test:3000","organization":{"name":"Evil Corp","support_email":"a@b.test"},"enrollment_methods":[]}
JSON
python3 -m http.server 8931 --directory "$stub_dir" >/dev/null 2>&1 &
good_pid=$!
python3 -m http.server 8932 --directory "$stub_dir/bad" >/dev/null 2>&1 &
bad_pid=$!
trap 'kill $good_pid $bad_pid 2>/dev/null || true' EXIT
sleep 1

/opt/oma-id/bin/installer-choice validate http://127.0.0.1:8931 | grep -q 'CI Stub Org'
/opt/oma-id/bin/installer-choice validate http://127.0.0.1:8931 | grep -q 'Compare the requested origin'

echo '=== installer-choice: wrong-protocol metadata must be rejected ==='
if /opt/oma-id/bin/installer-choice validate http://127.0.0.1:8932 >/dev/null 2>&1; then
  echo 'FAIL: wrong-protocol metadata must be rejected'
  exit 1
fi

echo '=== installer-choice: unreachable server must fail ==='
if /opt/oma-id/bin/installer-choice validate http://127.0.0.1:9 >/dev/null 2>&1; then
  echo 'FAIL: unreachable server must fail'
  exit 1
fi

echo '=== installer-choice: invalid origin must fail ==='
if /opt/oma-id/bin/installer-choice validate not-a-url >/dev/null 2>&1; then
  echo 'FAIL: invalid origin must fail'
  exit 1
fi

echo '=== installer-choice: validate under zsh (compat) ==='
zsh /opt/oma-id/bin/installer-choice validate http://127.0.0.1:8931 | grep -q 'CI Stub Org'

echo 'ALL LAYER CI TESTS GREEN'
