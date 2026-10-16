#!/usr/bin/env bats
# components/allowlist_addon.py: parsing, allow semantics, session liveness,
# the CONNECT-stage and request-stage refusals, response streaming. Runs with
# a stub `mitmproxy` module, so no mitmproxy install is needed.

setup() {
  load "$BATS_TEST_DIRNAME/../helpers/common"
  ADDON="${AGENT_SANDBOX_TEST_ADDON:-$REPO_ROOT/components/allowlist_addon.py}"
  CFG="$BATS_TEST_TMPDIR/cfg"
  BASE="$BATS_TEST_TMPDIR/base"
  mkdir -p "$CFG" "$BASE" "$BATS_TEST_TMPDIR/stub/mitmproxy"
  cp "$BATS_TEST_DIRNAME/../helpers/mitmproxy_stub.py" "$BATS_TEST_TMPDIR/stub/mitmproxy/http.py"
  : >"$BATS_TEST_TMPDIR/stub/mitmproxy/__init__.py"
  export PYTHONPATH="$BATS_TEST_TMPDIR/stub" AGENT_SANDBOX_SESSION_BASE="$BASE"
  printf '# comment\napi.github.com   # trailing\n\n.example.org\n' >"$CFG/allowlist.txt"
  # The proxy serves live sessions only: the plain scenarios speak for this one, owned
  # by the test itself; DRIVE_TOKEN= makes a client anonymous.
  mkdir -p "$BASE/session.live"
  printf '%s %s\n' "$$" "$(awk '{print $22}' "/proc/$$/stat")" >"$BASE/session.live/owner.id"
  echo LIVE >"$BASE/session.live/proxy.token"
  : >"$BASE/session.live/allow.txt"
  export DRIVE_TOKEN=LIVE
}

# AGENT_SANDBOX_TEST_PYTHON may wrap the interpreter, e.g. "python3 -m trace --count ..." for coverage.
# shellcheck disable=SC2086
drive() { ${AGENT_SANDBOX_TEST_PYTHON:-python3} "$BATS_TEST_DIRNAME/../helpers/addon_driver.py" "$ADDON" "$CFG" "$@"; }

@test "the allowlist parses comments and whitespace; a leading dot means the domain and its subdomains" {
  run drive parse
  [ "$status" -eq 0 ]
  [[ "$output" == *"exact=api.github.com,example.org"* ]]
  [[ "$output" == *"suffix=.example.org"* ]]
  run drive allowed api.github.com example.org www.example.org notexample.org github.com
  [[ "$output" == *"api.github.com=True"* ]]
  [[ "$output" == *"example.org=True"* ]]
  [[ "$output" == *"www.example.org=True"* ]]
  [[ "$output" == *"notexample.org=False"* ]]
  [[ "$output" == *"github.com=False"* ]]
}

@test "a session's --allow counts only with that session's token, only while its owner is alive; a recycled pid never counts" {
  sleep 300 &
  local live=$!
  local st
  st=$(awk '{print $22}' "/proc/$live/stat")
  mkdir -p "$BASE/session.a" "$BASE/session.dead" "$BASE/session.recycled" "$BASE/session.noowner"
  printf '%s %s\n' "$live" "$st" >"$BASE/session.a/owner.id"
  printf '# header\npypi.org\n' >"$BASE/session.a/allow.txt"
  echo "tokenA" >"$BASE/session.a/proxy.token"
  echo "999999 1" >"$BASE/session.dead/owner.id"
  echo "dead.example" >"$BASE/session.dead/allow.txt"
  echo "tokenD" >"$BASE/session.dead/proxy.token"
  printf '%s %s\n' "$live" "1" >"$BASE/session.recycled/owner.id"
  echo "recycled.example" >"$BASE/session.recycled/allow.txt"
  echo "tokenR" >"$BASE/session.recycled/proxy.token"
  echo "noowner.example" >"$BASE/session.noowner/allow.txt"
  echo "tokenN" >"$BASE/session.noowner/proxy.token"
  # session.a's pypi.org is reachable ONLY with tokenA and while alive
  run drive allowed_tok tokenA pypi.org
  [[ "$output" == *"pypi.org=True"* ]]
  run drive allowed_tok tokenA dead.example recycled.example noowner.example
  [[ "$output" == *"dead.example=False"* ]]     # dead owner: never
  [[ "$output" == *"recycled.example=False"* ]] # recycled pid (start-time differs): never
  [[ "$output" == *"noowner.example=False"* ]]  # unstamped: never
  # the global list is always allowed, token or not; an unknown/absent token gets global only
  run drive allowed_tok tokenA api.github.com
  [[ "$output" == *"api.github.com=True"* ]]
  run drive allowed_tok "" pypi.org api.github.com
  [[ "$output" == *"pypi.org=False"* ]]      # no token: session --allow invisible
  [[ "$output" == *"api.github.com=True"* ]] # but the global list still applies
  run drive allowed_tok wrongtoken pypi.org
  [[ "$output" == *"pypi.org=False"* ]] # a non-matching token gets nothing extra
  kill "$live"
  wait "$live" 2>/dev/null || true
  run drive allowed_tok tokenA pypi.org
  [[ "$output" == *"pypi.org=False"* ]] # owner gone: the grant lapses even with the token
}

@test "--allow is isolated between concurrent sessions; the token rides CONNECT and inner tunnel requests inherit it" {
  sleep 300 &
  local live=$!
  local st
  st=$(awk '{print $22}' "/proc/$live/stat")
  mkdir -p "$BASE/session.a" "$BASE/session.b"
  printf '%s %s\n' "$live" "$st" >"$BASE/session.a/owner.id"
  echo "AAA" >"$BASE/session.a/proxy.token"
  echo "a.example" >"$BASE/session.a/allow.txt"
  printf '%s %s\n' "$live" "$st" >"$BASE/session.b/owner.id"
  echo "BBB" >"$BASE/session.b/proxy.token"
  echo "b.example" >"$BASE/session.b/allow.txt"
  # CONNECT: A reaches a.example with A's token; B (or no token) cannot
  run drive connect_tok AAA a.example
  [[ "$output" == *"blocked=False"* ]]
  run drive connect_tok BBB a.example
  [[ "$output" == *"blocked=True"* ]]
  run drive connect_tok none a.example
  [[ "$output" == *"blocked=True"* ]]
  run drive connect_tok BBB b.example
  [[ "$output" == *"blocked=False"* ]]
  # HTTPS tunnel: the CONNECT carries the token, the inner request (no header) inherits it
  run drive tunnel_tok AAA a.example a.example
  [[ "$output" == *"connect_blocked=False"* && "$output" == *"request_blocked=False"* ]]
  # after the client disconnects, the tunnel's remembered token is dropped
  run drive disconnect_tok AAA a.example
  [[ "$output" == *"after_disconnect_blocked=True"* ]]
  # a malformed Proxy-Authorization is no token: anonymous, refused even for a global host
  run drive connect_badauth a.example
  [[ "$output" == *"blocked=True"* ]]
  run drive connect_badauth api.github.com
  [[ "$output" == *"blocked=True"* ]]
  kill "$live"
  wait "$live" 2>/dev/null || true
}

@test "a session's [deny] takes hosts out of the global list and its own grant, for that session only (#221)" {
  sleep 300 &
  local live=$!
  local st
  st=$(awk '{print $22}' "/proc/$live/stat")
  mkdir -p "$BASE/session.a" "$BASE/session.b"
  printf '%s %s\n' "$live" "$st" | tee "$BASE/session.a/owner.id" >"$BASE/session.b/owner.id"
  echo "AAA" >"$BASE/session.a/proxy.token"
  echo "BBB" >"$BASE/session.b/proxy.token"
  printf 'a.example\n' >"$BASE/session.a/allow.txt"
  printf 'api.github.com\n.example.org\n' >"$BASE/session.a/deny.txt"
  : >"$BASE/session.b/allow.txt"
  run drive connect_tok AAA api.github.com # in the global list, denied here
  [[ "$output" == *"blocked=True"* ]]
  run drive connect_tok AAA www.example.org # a suffix line denies the subdomains too
  [[ "$output" == *"blocked=True"* ]]
  run drive connect_tok AAA a.example # its own grant, not denied
  [[ "$output" == *"blocked=False"* ]]
  run drive request_tok AAA api.github.com
  [[ "$output" == *"blocked=True"* && "$output" == *"denied for this session"* ]]
  run drive connect_tok BBB api.github.com # another session: the global list still applies
  [[ "$output" == *"blocked=False"* ]]
  run drive connect api.github.com # a session without the line: likewise
  [[ "$output" == *"blocked=False"* ]]
  kill "$live"
  wait "$live" 2>/dev/null || true
}

@test "a retrieve-only session: GET and HEAD pass, every other method is refused, but to the profile's own hosts (#223)" {
  sleep 300 &
  local live=$!
  local st
  st=$(awk '{print $22}' "/proc/$live/stat")
  mkdir -p "$BASE/session.a" "$BASE/session.b"
  printf '%s %s\n' "$live" "$st" | tee "$BASE/session.a/owner.id" >"$BASE/session.b/owner.id"
  echo "AAA" >"$BASE/session.a/proxy.token"
  echo "BBB" >"$BASE/session.b/proxy.token"
  printf 'api.anthropic.com\n' >"$BASE/session.a/allow.txt"
  printf 'api.anthropic.com\n' >"$BASE/session.a/retrieve-only.txt"
  : >"$BASE/session.b/allow.txt"
  run drive request_body AAA api.github.com GET /repos/x/y/issues
  [[ "$output" == *"blocked=False"* ]]
  run drive request_body AAA api.github.com HEAD /
  [[ "$output" == *"blocked=False"* ]]
  run drive request_body AAA api.github.com POST /repos/x/y/issues '{"title":"t"}'
  [[ "$output" == *"blocked=True"* && "$output" == *"POST (this session is retrieve-only"* ]]
  run drive request_body AAA api.github.com PATCH /repos/x/y/issues/1 '{}'
  [[ "$output" == *"blocked=True"* ]]
  run drive request_body AAA api.anthropic.com POST /v1/messages '{}' # the profile's own
  [[ "$output" == *"blocked=False"* ]]
  run drive request_body BBB api.github.com POST /repos/x/y/issues '{}' # another session
  [[ "$output" == *"blocked=False"* ]]
  grep -q $'\tapi.github.com\tPOST\t/repos/x/y/issues$' "$CFG/blocked.log"
  kill "$live"
  wait "$live" 2>/dev/null || true
}

@test "a retrieve-only session: a GraphQL query to api.github.com passes, a mutation is refused, by the body (#223)" {
  sleep 300 &
  local live=$!
  local st
  st=$(awk '{print $22}' "/proc/$live/stat")
  mkdir -p "$BASE/session.a"
  printf '%s %s\n' "$live" "$st" >"$BASE/session.a/owner.id"
  echo "AAA" >"$BASE/session.a/proxy.token"
  : >"$BASE/session.a/allow.txt"
  : >"$BASE/session.a/retrieve-only.txt"
  run drive request_body AAA api.github.com POST /graphql '{"query":"query { repository(owner:\"x\", name:\"y\") { issue(number: 1) { title } } }"}'
  [[ "$output" == *"blocked=False"* ]]
  run drive request_body AAA api.github.com POST /graphql '{"query":"{ search(query: \"mutation\", type: ISSUE) { issueCount } }"}' # a string is not syntax
  [[ "$output" == *"blocked=False"* ]]
  run drive request_body AAA api.github.com POST /graphql '{"query":"mutation { addComment(input: {subjectId: \"x\", body: \"y\"}) { clientMutationId } }"}'
  [[ "$output" == *"blocked=True"* && "$output" == *"a GraphQL mutation"* ]]
  run drive request_body AAA api.github.com POST /graphql '{"query":"query A { a } mutation B { b }","operationName":"A"}' # any mutation in the document
  [[ "$output" == *"blocked=True"* ]]
  run drive request_body AAA api.github.com POST /graphql '[{"query":"{ a }"},{"query":"mutation { b }"}]' # a batch
  [[ "$output" == *"blocked=True"* ]]
  run drive request_body AAA api.github.com POST /graphql 'not json'
  [[ "$output" == *"blocked=True"* ]]
  run drive request_body AAA example.org POST /graphql '{"query":"{ a }"}' # only GitHub's endpoint is GraphQL-aware
  [[ "$output" == *"blocked=True"* ]]
  kill "$live"
  wait "$live" 2>/dev/null || true
}

@test "a request that belongs to no live session gets 407 with a Basic challenge, on CONNECT and plain HTTP alike, even for a global host" {
  # Measured on mitmproxy 12.2.2: before this, a client without the token (git, whose
  # libcurl waits for a challenge, or an agent that dropped it from HTTPS_PROXY) got the
  # global list and none of its session's [deny], retrieve-only or git refusal.
  DRIVE_TOKEN='' run drive connect api.github.com
  [[ "$output" == *"blocked=True"* && "$output" == *"status=407"* ]]
  [[ "$output" == *'challenge=Basic realm="agent-sandbox"'* ]]
  DRIVE_TOKEN='' run drive request api.github.com GET /zen
  [[ "$output" == *"status=407"* && "$output" == *"no live session's token"* ]]
  grep -q $'\tapi.github.com\tCONNECT\t-\tno session$' "$CFG/blocked.log"
  DRIVE_TOKEN=nosuch run drive connect api.github.com # a token no live session has
  [[ "$output" == *"status=407"* ]]
  run drive connect api.github.com # the session's own token
  [[ "$output" == *"blocked=False"* ]]
}

@test "a session with git = refuse: git's smart-HTTP transport is refused to any host, everything else passes (#224)" {
  sleep 300 &
  local live=$!
  local st
  st=$(awk '{print $22}' "/proc/$live/stat")
  mkdir -p "$BASE/session.a" "$BASE/session.b"
  printf '%s %s\n' "$live" "$st" | tee "$BASE/session.a/owner.id" >"$BASE/session.b/owner.id"
  echo "AAA" >"$BASE/session.a/proxy.token"
  echo "BBB" >"$BASE/session.b/proxy.token"
  : >"$BASE/session.a/allow.txt"
  : >"$BASE/session.b/allow.txt"
  : >"$BASE/session.a/git-refuse.txt"
  printf 'github.com\n' >>"$CFG/allowlist.txt"
  run drive request_ua AAA github.com GET '/x/y.git/info/refs?service=git-upload-pack' ''
  [[ "$output" == *"blocked=True"* && "$output" == *"git's transport"* ]]
  run drive request_ua AAA github.com GET '/x/y.git/info/refs?service=git-receive-pack' ''
  [[ "$output" == *"blocked=True"* ]]
  run drive request_ua AAA github.com POST /x/y.git/git-receive-pack ''
  [[ "$output" == *"blocked=True"* ]]
  run drive request_ua AAA api.github.com GET /zen 'git/2.43.0' # git's own user agent, any path
  [[ "$output" == *"blocked=True"* ]]
  run drive request_ua AAA github.com GET /x/y 'Mozilla/5.0' # a page
  [[ "$output" == *"blocked=False"* ]]
  run drive request_ua AAA github.com GET /x/y/info/refs '' # not git's service query
  [[ "$output" == *"blocked=False"* ]]
  run drive request_ua BBB github.com GET '/x/y.git/info/refs?service=git-upload-pack' 'git/2.43.0' # another session
  [[ "$output" == *"blocked=False"* ]]
  kill "$live"
  wait "$live" 2>/dev/null || true
}

@test "a session with git = fetch: git's fetch passes, its push is refused (#github)" {
  mkdir -p "$BASE/session.f"
  printf '%s %s\n' "$$" "$(awk '{print $22}' "/proc/$$/stat")" >"$BASE/session.f/owner.id"
  echo FFF >"$BASE/session.f/proxy.token"
  : >"$BASE/session.f/allow.txt"
  : >"$BASE/session.f/git-push-refuse.txt"
  printf 'github.com\n' >>"$CFG/allowlist.txt"
  run drive request_ua FFF github.com GET '/x/y.git/info/refs?service=git-upload-pack' 'git/2.43.0'
  [[ "$output" == *"blocked=False"* ]]
  run drive request_ua FFF github.com POST /x/y.git/git-upload-pack 'git/2.43.0'
  [[ "$output" == *"blocked=False"* ]]
  run drive request_ua FFF github.com GET '/x/y.git/info/refs?service=git-receive-pack' 'git/2.43.0'
  [[ "$output" == *"blocked=True"* && "$output" == *"git = fetch"* ]]
  run drive request_ua FFF github.com POST /x/y.git/git-receive-pack 'git/2.43.0'
  [[ "$output" == *"blocked=True"* ]]
}

@test "a retrieve-only session fetches with git where [net] git permits it, and never pushes (#280)" {
  # git's fetch is a POST to git-upload-pack: it reads, as a GraphQL query does.
  local R="$BASE/session.live/refused.log" adv='/x/y.git/info/refs?service=git-upload-pack'
  local radv='/x/y.git/info/refs?service=git-receive-pack'
  : >"$R"
  printf 'github.com\n' >>"$CFG/allowlist.txt"
  : >"$BASE/session.live/retrieve-only.txt"
  # git = fetch: upload-pack passes, receive-pack is refused as a push
  : >"$BASE/session.live/git-push-refuse.txt"
  run drive request_ua LIVE github.com GET "$adv" 'git/2.43.0'
  [[ "$output" == *"blocked=False"* ]]
  run drive request_ua LIVE github.com POST /x/y.git/git-upload-pack 'git/2.43.0'
  [[ "$output" == *"blocked=False"* ]]
  run drive request_ua LIVE github.com GET "$radv" 'git/2.43.0'
  [[ "$output" == *"blocked=True"* && "$output" == *"git = fetch"* ]]
  run drive request_ua LIVE github.com POST /x/y.git/git-receive-pack 'git/2.43.0'
  [[ "$output" == *"blocked=True"* && "$output" == *"git = fetch"* ]]
  run drive request_ua LIVE github.com POST /x/y/issues 'git/2.43.0' # git's user agent is not a fetch
  [[ "$output" == *"blocked=True"* && "$output" == *"retrieve-only"* ]]
  rm "$BASE/session.live/git-push-refuse.txt"
  # git = allow: upload-pack passes, receive-pack is refused all the same
  run drive request_ua LIVE github.com POST /x/y.git/git-upload-pack 'git/2.43.0'
  [[ "$output" == *"blocked=False"* ]]
  run drive request_ua LIVE github.com GET "$radv" 'git/2.43.0'
  [[ "$output" == *"blocked=True"* && "$output" == *"retrieve-only"* ]]
  run drive request_ua LIVE github.com POST /x/y.git/git-receive-pack 'git/2.43.0'
  [[ "$output" == *"blocked=True"* && "$output" == *"retrieve-only"* ]]
  # git = refuse: upload-pack is refused as git's transport
  : >"$BASE/session.live/git-refuse.txt"
  run drive request_ua LIVE github.com GET "$adv" 'git/2.43.0'
  [[ "$output" == *"blocked=True"* && "$output" == *"git's transport"* ]]
  run drive request_ua LIVE github.com POST /x/y.git/git-upload-pack 'git/2.43.0'
  [[ "$output" == *"blocked=True"* && "$output" == *"git's transport"* ]]
  run cut -f2- "$R"
  [ "$output" = $'github.com\tGET\tgit push\ngithub.com\tPOST\tgit push\ngithub.com\tPOST\tretrieve-only\ngithub.com\tGET\tretrieve-only\ngithub.com\tPOST\tretrieve-only\ngithub.com\tGET\tgit refuse\ngithub.com\tPOST\tgit refuse' ]
}

@test "without retrieve-only, git = allow: git's fetch and push both pass (#280 leaves it)" {
  printf 'github.com\n' >>"$CFG/allowlist.txt"
  run drive request_ua LIVE github.com POST /x/y.git/git-upload-pack 'git/2.43.0'
  [[ "$output" == *"blocked=False"* ]]
  run drive request_ua LIVE github.com GET '/x/y.git/info/refs?service=git-receive-pack' 'git/2.43.0'
  [[ "$output" == *"blocked=False"* ]]
  run drive request_ua LIVE github.com POST /x/y.git/git-receive-pack 'git/2.43.0'
  [[ "$output" == *"blocked=False"* ]]
}

@test "a session with hosts = public: any host passes CONNECT and requests, POST too; [deny] and other sessions keep the allowlist" {
  mkdir -p "$BASE/session.p"
  printf '%s %s\n' "$$" "$(awk '{print $22}' "/proc/$$/stat")" >"$BASE/session.p/owner.id"
  echo PPP >"$BASE/session.p/proxy.token"
  : >"$BASE/session.p/allow.txt"
  : >"$BASE/session.p/hosts-public.txt"
  printf 'shop.example\n' >"$BASE/session.p/deny.txt"
  run drive connect_tok PPP store.example.net # on no list
  [[ "$output" == *"blocked=False"* ]]
  run drive request_body PPP store.example.net POST /search 'q=laptop'
  [[ "$output" == *"blocked=False"* ]]
  run drive connect_tok PPP shop.example # denied for this session, public or not
  [[ "$output" == *"blocked=True"* ]]
  run drive request_tok PPP shop.example
  [[ "$output" == *"blocked=True"* && "$output" == *"denied for this session"* ]]
  run drive connect_tok LIVE store.example.net # another session: the allowlist applies
  [[ "$output" == *"blocked=True"* ]]
  rm "$BASE/session.p/owner.id" # a session no longer live: refused like any anonymous client
  run drive connect_tok PPP store.example.net
  [[ "$output" == *"blocked=True"* && "$output" == *"status=407"* ]]
}

@test "a non-allowed request gets a 403 with the allowlist message and is logged; an allowed one passes" {
  run drive request blocked.invalid POST /v1/x
  [[ "$output" == *"blocked=True"* ]]
  [[ "$output" == *"status=403"* ]]
  [[ "$output" == *"body=agent-sandbox: host 'blocked.invalid' is not in the allowlist."* ]]
  grep -q $'\tblocked.invalid\tPOST\t/v1/x$' "$CFG/blocked.log"
  run drive request api.github.com
  [[ "$output" == *"blocked=False"* ]]
  [ "$(wc -l <"$CFG/blocked.log")" -eq 1 ]
}

@test "a non-allowed CONNECT is refused with 403 and logged as CONNECT; an allowed one passes" {
  run drive connect example.com
  [[ "$output" == *"blocked=True"* ]]
  [[ "$output" == *"status=403"* ]]
  grep -q $'\texample.com\tCONNECT\t-$' "$CFG/blocked.log"
  run drive connect sub.example.org
  [[ "$output" == *"blocked=False"* ]]
}

@test "responses are streamed" {
  run drive responseheaders text/event-stream
  [[ "$output" == "stream=True" ]]
  run drive responseheaders application/octet-stream
  [[ "$output" == "stream=True" ]]
}

@test "the destination gate uses the request-line host, not a spoofable Host header (F1)" {
  # `GET http://<dest>/` with `Host: <allowlisted>` must be judged on <dest>,
  # the address mitmproxy actually dials, not the Host header. api.github.com is
  # allowlisted (see setup); evil.example is not.
  run drive request_spoof evil.example api.github.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"blocked=True"* ]] # judged on the real destination
  run drive request_spoof api.github.com evil.example
  [[ "$output" == *"blocked=False"* ]] # allowlisted real destination passes
}

@test "_addr_is_public: public routable yes; loopback, private, link-local, ULA no" {
  run drive public 93.184.216.34 8.8.8.8 2606:4700:4700::1111
  [[ "$output" == *"93.184.216.34=True"* ]]
  [[ "$output" == *"8.8.8.8=True"* ]]
  [[ "$output" == *"2606:4700:4700::1111=True"* ]]
  run drive public 127.0.0.1 10.0.0.1 192.168.1.1 169.254.169.254 ::1 fd00::1 0.0.0.0
  local ip
  for ip in 127.0.0.1 10.0.0.1 192.168.1.1 169.254.169.254 ::1 fd00::1 0.0.0.0; do
    [[ "$output" == *"$ip=False"* ]]
  done
}

@test "server_connect refuses a non-public destination and passes a public one (F1)" {
  # literal IPs: no DNS needed
  run drive server_connect 127.0.0.1 9099
  [[ "$output" == *"aborted=True"* ]]
  run drive server_connect 169.254.169.254 80 # cloud metadata
  [[ "$output" == *"aborted=True"* ]]
  run drive server_connect 93.184.216.34 443 # public
  [[ "$output" == *"aborted=False"* ]]
}

@test "server_connect refuses an allowlisted NAME that resolves to a private address (DNS rebinding)" {
  # the name gate would allow it; the destination gate resolves and refuses.
  run drive server_connect_resolve rebind.example 127.0.0.1
  [[ "$output" == *"aborted=True"* ]]
  run drive server_connect_resolve legit.example 93.184.216.34
  [[ "$output" == *"aborted=False"* ]]
  # a name resolving to BOTH public and private is refused (any bad answer loses)
  run drive server_connect_resolve mixed.example 93.184.216.34 127.0.0.1
  [[ "$output" == *"aborted=True"* ]]
}

@test "a session's refusal is also appended to its own refused.log, with the reason; nothing reaches another session's" {
  mkdir -p "$BASE/session.o"
  printf '%s %s\n' "$$" "$(awk '{print $22}' "/proc/$$/stat")" >"$BASE/session.o/owner.id"
  echo OTHER >"$BASE/session.o/proxy.token"
  : >"$BASE/session.o/allow.txt"
  : >"$BASE/session.o/refused.log"
  local R="$BASE/session.live/refused.log"
  : >"$R"
  printf 'denied.example\n' >"$BASE/session.live/deny.txt"
  printf 'denied.example\n' >>"$CFG/allowlist.txt"
  run drive connect prefix.dev # not on the allowlist
  [[ "$output" == *"status=403"* ]]
  run drive request blocked.invalid POST /v1/x
  [[ "$output" == *"status=403"* ]]
  run drive connect denied.example
  [[ "$output" == *"status=403"* ]]
  run drive connect api.github.com # allowed: no line
  [[ "$output" == *"blocked=False"* ]]
  [ "$(wc -l <"$R")" -eq 3 ]
  local ts='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'
  grep -qE "^$ts"$'\tprefix\\.dev\tCONNECT\tallowlist$' "$R"
  grep -qE "^$ts"$'\tblocked\\.invalid\tPOST\tallowlist$' "$R"
  grep -qE "^$ts"$'\tdenied\\.example\tCONNECT\t\\[deny\\]$' "$R"
  [ ! -s "$BASE/session.o/refused.log" ]   # another live session learns nothing of it
  [ "$(wc -l <"$CFG/blocked.log")" -eq 3 ] # the host-wide log still has every one
}

@test "a policy refusal names its reason in refused.log: retrieve-only, git refuse, git push, a non-public dial" {
  local R="$BASE/session.live/refused.log"
  : >"$R"
  printf 'github.com\n' >>"$CFG/allowlist.txt"
  : >"$BASE/session.live/retrieve-only.txt"
  run drive request_body LIVE api.github.com POST /repos/x/issues '{}'
  [[ "$output" == *"blocked=True"* ]]
  rm "$BASE/session.live/retrieve-only.txt"
  : >"$BASE/session.live/git-push-refuse.txt"
  run drive request_ua LIVE github.com POST /x/y.git/git-receive-pack 'git/2.43.0'
  [[ "$output" == *"blocked=True"* ]]
  : >"$BASE/session.live/git-refuse.txt"
  run drive request_ua LIVE github.com GET '/x/y.git/info/refs?service=git-upload-pack' 'git/2.43.0'
  [[ "$output" == *"blocked=True"* ]]
  printf '127.0.0.1\n' >>"$CFG/allowlist.txt"
  run drive tunnel_dest LIVE 127.0.0.1 # allowlisted by name, refused at the dial
  [[ "$output" == *"connect_blocked=False"* && "$output" == *"aborted=True"* ]]
  run cut -f2- "$R"
  [ "$output" = $'api.github.com\tPOST\tretrieve-only\ngithub.com\tPOST\tgit push\ngithub.com\tGET\tgit refuse\n127.0.0.1\tDEST\tnon-public' ]
}

@test "a refusal with no session goes to blocked.log only; an unwritable refused.log still gets the 403" {
  local R="$BASE/session.live/refused.log"
  : >"$R"
  DRIVE_TOKEN='' run drive connect prefix.dev
  [[ "$output" == *"status=407"* ]]
  grep -q $'\tprefix.dev\tCONNECT\t-\tno session$' "$CFG/blocked.log"
  [ ! -s "$R" ]
  # no refused.log (the session's briefing is off): none is created
  rm "$R"
  run drive connect prefix.dev
  [[ "$output" == *"status=403"* ]]
  [ ! -e "$R" ]
  # a write that fails changes nothing about the response
  : >"$R"
  chmod 0444 "$R"
  chmod 0555 "$BASE/session.live"
  run drive connect prefix.dev
  chmod 0755 "$BASE/session.live"
  [ "$status" -eq 0 ]
  [[ "$output" == *"blocked=True"* && "$output" == *"status=403"* ]]
  [ ! -s "$R" ]
  [ "$(grep -c $'\tprefix.dev\tCONNECT\t-$' "$CFG/blocked.log")" -eq 2 ]
}
