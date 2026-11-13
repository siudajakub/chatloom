# Instagram reel captions

The existing ChatLoom Instagram fork returns assets but no post caption from
`POST /v3/chatloom/link_media`. The client also accepts a matching bridge link
preview's description, but cannot invent an unavailable caption.

`instagram-link-captions.patch` adds optional `caption`, `canonical_url` and
`author` to metadata responses and preserves the parent caption on carousels.
Authentication, download URLs and the file response remain unchanged.

The patch was generated and apply-checked against
`siudajakub/chatloom-instagram-bridge` commit
`3497c049ae1ec1d403d4b6b94487dc1e5e97cb7a` (branch `chatloom/link-media`).
It is source for the bridge operator; it has not been deployed to a live VPS.

From a bridge checkout with no edits to `pkg/igconnector/linkmedia.go`:

```sh
git apply --check /path/to/chatloom/scripts/bridges/instagram-link-captions.patch
git apply /path/to/chatloom/scripts/bridges/instagram-link-captions.patch
gofmt -w pkg/igconnector/linkmedia.go
go test ./pkg/igconnector
./build-ig.sh
```

Keep the existing bridge configuration, database and login. Back them up before
replacing the binary; stop its old process before starting the new one. Do not
run a second instance on the same database. An unmodified official mautrix-meta
bridge does not gain the link-media endpoint from this caption-only patch.

Application tests exercise synthetic metadata/download responses and native
player fakes. Go compilation and real Instagram access need separate acceptance
in the bridge environment.
