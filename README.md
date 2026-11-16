# Journey into Math ClamAV mirror

This public repository publishes only ClamAV's public, digitally signed virus
definition databases for the `journeyintomath.ir` production host.

The Iranian production network cannot download from ClamAV's official CDN. A
GitHub-hosted runner therefore uses the supported `freshclam` client to fetch
and test the databases, then atomically deploys a bounded GitHub Pages artifact
containing one versioned database directory and `current.txt`.

No application source, production data, credentials, private endpoints, or
decryption keys belong in this repository. The production host downloads the
public manifest without a GitHub token and still lets `freshclam` verify every
database before activation.

The scheduled workflow also supports a manual run. The Pages site contains only
the current verified definition set, stays well below GitHub's published-site
limit, and records the served manifest in this repository only after deployment.

The same verified files are also published as the assets of the newest GitHub release, together
with `current.txt`, for hosts that cannot reach `github.io` but can reach `github.com`
(`releases/latest/download/current.txt`, then `releases/download/<tag>/<database>`). The release
holds copies of the deployed artifact only; the host still verifies every database signature. Only
the newest three releases are kept.
