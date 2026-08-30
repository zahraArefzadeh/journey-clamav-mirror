# Journey into Math ClamAV mirror

This public repository publishes only ClamAV's public, digitally signed virus
definition databases for the `journeyintomath.ir` production host.

The Iranian production network cannot download from ClamAV's official CDN. A
GitHub-hosted runner therefore uses the supported `freshclam` client to fetch
and test the databases, publishes them in an immutable versioned release, and
updates `current.txt` only after every release asset is available.

No application source, production data, credentials, private endpoints, or
decryption keys belong in this repository. The production host downloads the
public manifest without a GitHub token and still lets `freshclam` verify every
database before activation.

The scheduled workflow also supports a manual run. It retains the current and
seven previous database releases so the mirror stays bounded while preserving
more than the production seven-day definition-freshness window.
